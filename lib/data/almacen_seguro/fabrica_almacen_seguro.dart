import 'package:flutter/foundation.dart' show kIsWeb;

import 'almacen_seguro.dart';
import 'almacen_seguro_preferencias.dart';
import 'almacen_seguro_secure_storage.dart';

/// Único punto donde se decide el backend del almacén de secretos (HU-036).
///
/// Nativo (Android/iOS) → cifrado con respaldo de hardware. Web → SharedPreferences
/// (la implementación web del paquete es experimental y sin hardware: ver
/// [AlmacenSeguroPreferencias]).
AlmacenSeguro crearAlmacenSeguro() =>
    kIsWeb ? const AlmacenSeguroPreferencias() : AlmacenSeguroSecureStorage();

/// `true` si en esta plataforma los secretos quedan cifrados por el sistema.
/// Lo consulta el wiring para decidir si vale la pena migrar (en web el origen y
/// el destino serían el MISMO storage, así que no hay nada que migrar).
bool get almacenSeguroEsCifrado => !kIsWeb;
