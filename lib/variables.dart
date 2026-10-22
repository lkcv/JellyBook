// The purpose of this file is to store all global variables.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

// get the ApplicationDocumentsDirectory path

late String localPath;
String logStoragePath = "/storage/emulated/0/Documents/";

Logger logger = Logger(
  output: kDebugMode
      ? ConsoleOutput()
      : FileOutput(
          file: File("$localPath/kurage.log"),
          overrideExisting: false,
          encoding: utf8,
          sink: IOSink(File("$localPath/kurage.log")
              .openWrite(mode: FileMode.writeOnlyAppend, encoding: utf8)),
        ),
  level: Level.debug,
  printer: kDebugMode
      ? PrettyPrinter(dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart, printEmojis: true, colors: true)
      : PrettyPrinter(
          methodCount: 5,
          errorMethodCount: 8,
          lineLength: 120,
          colors: false,
          printEmojis: true,
          dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
        ),
);

class FileOutput extends LogOutput {
  final File file;
  final bool overrideExisting;
  final Encoding encoding;
  late IOSink sink;

  FileOutput({
    required this.file,
    this.overrideExisting = false,
    this.encoding = utf8,
    IOSink? sink,
  }) {
    this.sink = sink ??
        file.openWrite(
          mode:
              overrideExisting ? FileMode.writeOnly : FileMode.writeOnlyAppend,
          encoding: encoding,
        );
  }

  @override
  void output(OutputEvent event) {
    sink.writeAll(event.lines, '\n');
  }

  @override
  Future<void> destroy() async {
    await sink.flush();
    await sink.close();
  }
}
