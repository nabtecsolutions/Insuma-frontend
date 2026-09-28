import 'package:shared_preferences/shared_preferences.dart';

import 'almacen_seguro.dart';

/// Lectura con MIGRACIÓN read-through (HU-036).
///
/// Garantía central de la HU: **ninguna instalación existente se desloguea**. Al
/// leer un secreto se busca primero en el almacén seguro; si no está (instalación
/// que viene de una versión anterior), se lee la copia vieja EN CLARO de
/// SharedPreferences, se copia al almacén seguro y se BORRA la vieja. A partir de
/// ahí el secreto solo vive cifrado.
///
/// [lectorViejo] permite migrar claves que no eran String en prefs (p. ej. el
/// bool `insuma_es_superadmin`), serializándolas al formato del almacén.
Future<String?> leerOMigrar({
  required AlmacenSeguro seguro,
  required SharedPreferences prefs,
  required String clave,
  String? Function(SharedPreferences prefs, String clave)? lectorViejo,

  /// `false` en plataformas donde origen y destino son el MISMO storage (web):
  /// ahí no hay nada que migrar ni que borrar.
  bool migrar = true,
}) async {
  final actual = await seguro.leer(clave);
  if (actual != null) return actual;
  if (!migrar) return null;

  final viejo = lectorViejo != null
      ? lectorViejo(prefs, clave)
      : prefs.getString(clave);
  if (viejo == null) return null;

  await seguro.escribir(clave, viejo);
  await prefs.remove(clave); // se elimina la copia en claro: objetivo de la HU
  return viejo;
}

/// Lector para claves que en la versión vieja se guardaban como `bool`.
String? lectorBoolViejo(SharedPreferences prefs, String clave) =>
    prefs.getBool(clave)?.toString();
