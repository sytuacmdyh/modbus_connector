import 'dart:io';

Map<String, Object?>? fileErrorDetails(Object error) =>
    error is FileSystemException
    ? {'path': error.path ?? '', 'code': error.osError?.errorCode ?? '—'}
    : null;
