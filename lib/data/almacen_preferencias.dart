import 'package:shared_preferences/shared_preferences.dart';

/// Almacenamiento de las preferencias del dispositivo (HU-054).
///
/// Existe como contrato, y no como llamadas directas a `SharedPreferences`,
/// por la misma razón que [AlmacenSeguro] en la capa de identidad: la API del
/// paquete no es inyectable (`getInstance()` es un singleton estático), así que
/// sin esta costura el camino de ESCRITURA FALLIDA no se puede testear sin
/// pisar `SharedPreferencesStorePlatform.instance` — un global compartido entre
/// tests, que hay que acordarse de restaurar y que además no se comporta como
/// el almacén real (la caché en memoria de `SharedPreferences` se escribe ANTES
/// de delegar, así que una escritura rechazada sigue leyéndose como exitosa).
abstract class AlmacenPreferencias {
  Future<String?> leer(String clave);

  /// Devuelve si quedó efectivamente guardado.
  Future<bool> escribir(String clave, String valor);
}

/// Implementación sobre `SharedPreferences`.
class AlmacenPreferenciasCompartidas implements AlmacenPreferencias {
  const AlmacenPreferenciasCompartidas();

  @override
  Future<String?> leer(String clave) async {
    try {
      return (await SharedPreferences.getInstance()).getString(clave);
    } catch (_) {
      // Una lectura fallida NO puede tumbar el arranque: la preferencia cae en
      // su valor por defecto y la app abre igual.
      return null;
    }
  }

  @override
  Future<bool> escribir(String clave, String valor) async {
    // `SharedPreferences` falla de DOS formas distintas según la plataforma, y
    // acá se unifican en una sola:
    //
    // - Devolviendo `false` (canal de plataforma que rechaza la escritura).
    // - **Lanzando.** El backend web hace `localStorage.setItem` sin `try`, así
    //   que con el almacenamiento lleno o en modo privado de Safari la promesa
    //   se rechaza. INSUMA tiene build web, así que no es hipotético.
    //
    // Quien llama sólo necesita saber si quedó guardado; que además tenga que
    // acordarse de capturar es cómo se pierde el error en silencio.
    try {
      return await (await SharedPreferences.getInstance()).setString(
        clave,
        valor,
      );
    } catch (_) {
      return false;
    }
  }
}
