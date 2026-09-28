import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../services/servicio_configuracion.dart';

/// Abre la conexión nativa de base de datos SQLite (Android, iOS, macOS, Windows, Linux).
/// Soporta configuración dinámica de ruta de archivo y base de datos volátil en memoria.
QueryExecutor connect() {
  return LazyDatabase(() async {
    // 1. Verificar si se configuró el uso de base de datos en memoria
    final usarEnMemoria = ServicioConfiguracion.obtenerBooleano(
      'APP_USE_MEMORY_DB',
      valorPorDefecto: false,
    );
    if (usarEnMemoria) {
      return NativeDatabase.memory();
    }

    // 2. Verificar si se especificó una ruta de base de datos externa personalizada
    final rutaPersonalizada = ServicioConfiguracion.obtener(
      'APP_DATABASE_PATH',
    );
    if (rutaPersonalizada.isNotEmpty) {
      return NativeDatabase.createInBackground(File(rutaPersonalizada));
    }

    // 3. Ruta por defecto: directorio de documentos del sistema de la aplicación
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'insuma.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
