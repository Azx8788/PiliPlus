import 'dart:convert' show jsonDecode;
import 'dart:io' show File;

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

class ParseVideoResult {
  final String videoUrl;

  /// 实际返回的清晰度代码（仅 Kina 风格接口有效）
  final int quality;

  /// 可用清晰度代码列表（仅 Kina 风格接口有效）
  final List<int> acceptQuality;

  const ParseVideoResult({
    required this.videoUrl,
    this.quality = 0,
    this.acceptQuality = const [],
  });
}

typedef ParseVideoResponse = ({String? error, ParseVideoResult? result});

abstract final class ParseVideoApi {
  // 独立 Dio：不携带 B 站 cookie / 请求头，避免泄露给第三方接口
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.plain,
      headers: {
        'user-agent':
            'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      },
    ),
  );

  static final Dio _downloadDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 30),
      headers: {
        'user-agent':
            'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      },
    ),
  );

  /// 清晰度代码 → 显示文本
  static String qualityLabel(int q) => switch (q) {
    127 => '8K 超高清',
    126 => '杜比视界',
    125 => 'HDR 真彩',
    120 => '4K 超清',
    116 => '1080P60',
    112 => '1080P+ 高码率',
    80 => '1080P 高清',
    74 => '720P60',
    64 => '720P 高清',
    32 => '480P 清晰',
    16 => '360P 流畅',
    _ => '清晰度 $q',
  };

  /// 构建请求地址：
  /// - 含 {bv} / {p} / {q} 占位符：按模板替换（Kina 风格，支持清晰度选择）
  /// - 含 {url} 占位符：替换为完整视频链接
  /// - 其他：默认拼接 url 与 type=json 参数（米人API 兼容）
  static String buildRequestUrl({
    required String api,
    required String bvid,
    required int page,
    required int quality,
    String? sessData,
  }) {
    final videoUrl =
        'https://www.bilibili.com/video/$bvid${page > 1 ? '?p=$page' : ''}';
    late String url;
    if (api.contains('{bv}') || api.contains('{p}') || api.contains('{q}')) {
      url = api
          .replaceFirst('{bv}', bvid)
          .replaceFirst('{p}', page.toString())
          .replaceFirst('{q}', quality.toString());
    } else if (api.contains('{url}')) {
      url = api.replaceFirst('{url}', Uri.encodeComponent(videoUrl));
    } else {
      url =
          '$api${api.contains('?') ? '&' : '?'}url=${Uri.encodeComponent(videoUrl)}&type=json';
    }
    if (sessData != null && sessData.isNotEmpty) {
      url += '${url.contains('?') ? '&' : '?'}cookie=SESSDATA=$sessData';
    }
    return url;
  }

  static Future<ParseVideoResponse> parse({
    required String bvid,
    int page = 1,
    int quality = 80,
    String? sessData,
  }) async {
    final api = Pref.parseApiUrl;
    if (api.isEmpty) {
      return (error: '未配置视频解析接口', result: null);
    }
    try {
      final resp = await _dio.get<String>(
        buildRequestUrl(
          api: api,
          bvid: bvid,
          page: page,
          quality: quality,
          sessData: sessData,
        ),
      );
      if (resp.data case final String body?) {
        try {
          return _parseResult(jsonDecode(body) as Map<String, dynamic>);
        } catch (_) {
          return (error: '解析接口返回非 JSON 数据，请更换接口', result: null);
        }
      }
      return (error: '解析接口返回格式异常，请更换接口', result: null);
    } on DioException catch (e) {
      return (
        error: '解析接口请求失败（接口可能已失效，可在设置中更换）\n${e.message ?? e.type}',
        result: null,
      );
    } catch (e) {
      return (error: '解析失败：$e', result: null);
    }
  }

  static ParseVideoResponse _parseResult(Map<String, dynamic> json) {
    final code = json['code'];
    // Kina 风格: {code: 0, quality, accept_quality: [..], url}
    if (code == 0) {
      final url = json['url'] as String?;
      if (url == null || url.isEmpty) {
        return (error: '未解析到视频链接', result: null);
      }
      return (
        error: null,
        result: ParseVideoResult(
          videoUrl: url,
          quality: json['quality'] as int? ?? 0,
          acceptQuality:
              (json['accept_quality'] as List?)
                  ?.map((e) => int.tryParse(e.toString()) ?? 0)
                  .where((e) => e > 0)
                  .toList() ??
              const [],
        ),
      );
    }
    // 米人API 风格: {code: 200, data: [{video_url, ...}]}
    if (code == 200 || code == '200') {
      final data = json['data'];
      Map<String, dynamic>? first;
      if (data is List && data.isNotEmpty) {
        first = Map<String, dynamic>.from(data.first);
      } else if (data is Map) {
        first = Map<String, dynamic>.from(data);
      }
      final url = (first?['video_url'] ?? first?['url']) as String?;
      if (url == null || url.isEmpty) {
        return (error: '未解析到可下载的视频', result: null);
      }
      return (error: null, result: ParseVideoResult(videoUrl: url));
    }
    return (
      error: '解析失败：${json['message'] ?? json['msg'] ?? 'code $code'}',
      result: null,
    );
  }

  static Future<bool> downloadVideo({
    required String url,
    required String savePath,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      await _downloadDio.download(
        url,
        savePath,
        cancelToken: cancelToken,
        options: Options(headers: {'referer': 'https://www.bilibili.com/'}),
        onReceiveProgress: onProgress,
      );
      return true;
    } catch (_) {
      // 删除未完成的文件
      try {
        final file = File(savePath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {}
      return false;
    }
  }
}
