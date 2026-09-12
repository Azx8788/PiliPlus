import 'dart:convert' show jsonDecode;
import 'dart:io' show File;

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

class ParseVideoItem {
  final String title;
  final int? duration;
  final String? durationFormat;
  final List<String> accept;
  final String videoUrl;

  const ParseVideoItem({
    required this.title,
    this.duration,
    this.durationFormat,
    this.accept = const [],
    required this.videoUrl,
  });

  factory ParseVideoItem.fromJson(Map<String, dynamic> json) => ParseVideoItem(
    title: json['title'] as String? ?? '',
    duration: json['duration'] as int?,
    durationFormat: json['durationFormat'] as String?,
    accept:
        (json['accept'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    videoUrl: (json['video_url'] ?? json['url']) as String? ?? '',
  );

  String get qualityLabel =>
      accept.isNotEmpty ? accept.join(' / ') : '默认清晰度';
}

class ParseVideoResult {
  final String title;
  final String? cover;
  final List<ParseVideoItem> items;

  const ParseVideoResult({
    required this.title,
    this.cover,
    required this.items,
  });

  factory ParseVideoResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    List<ParseVideoItem> items;
    if (data is List) {
      items = data
          .map((e) => ParseVideoItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } else if (data is Map) {
      items = [ParseVideoItem.fromJson(Map<String, dynamic>.from(data))];
    } else {
      items = const [];
    }
    return ParseVideoResult(
      title: json['title'] as String? ?? '',
      cover: json['imgurl'] as String?,
      items: items.where((e) => e.videoUrl.isNotEmpty).toList(),
    );
  }
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

  /// 拼接请求地址：
  /// - 接口地址含 {url} 占位符时，直接替换为编码后的视频链接
  /// - 否则默认追加 url 与 type=json 参数
  static String buildRequestUrl(String api, String videoUrl) {
    final encoded = Uri.encodeComponent(videoUrl);
    if (api.contains('{url}')) {
      return api.replaceFirst('{url}', encoded);
    }
    return '$api${api.contains('?') ? '&' : '?'}url=$encoded&type=json';
  }

  static Future<ParseVideoResponse> parse(String videoUrl) async {
    final api = Pref.parseApiUrl;
    if (api.isEmpty) {
      return (error: '未配置视频解析接口', result: null);
    }
    try {
      final resp = await _dio.get<String>(buildRequestUrl(api, videoUrl));
      final String body;
      if (resp.data case final String str?) {
        body = str;
      } else {
        return (error: '解析接口返回格式异常，请更换接口', result: null);
      }
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        return (error: '解析接口返回非 JSON 数据，请更换接口', result: null);
      }
      final code = json['code'];
      if (code == 200 || code == '200') {
        final result = ParseVideoResult.fromJson(json);
        if (result.items.isEmpty) {
          return (error: '未解析到可下载的视频（合集/番剧等暂不支持）', result: null);
        }
        return (error: null, result: result);
      }
      return (error: '解析失败：${json['msg'] ?? 'code $code'}', result: null);
    } on DioException catch (e) {
      return (
        error: '解析接口请求失败（接口可能已失效，可在设置中更换）\n${e.message ?? e.type}',
        result: null,
      );
    } catch (e) {
      return (error: '解析失败：$e', result: null);
    }
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
