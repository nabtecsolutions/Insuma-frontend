import 'package:flutter/material.dart';

import '../data/almacen_preferencias.dart';
import '../data/claves_dispositivo.dart';
import '../models/preferencias/tamano_tipografia.dart';

/// Preferencias de APARIENCIA del dispositivo (HU-054).
///
/// **Son del aparato, no de la cuenta.** No van al backend ni se sincronizan: la
/// tablet de la cocina, de pie y a un metro, y el celular del dueño no tienen por
/// qué verse igual. Esa decisión es la que hace que este servicio no necesite
/// migración, ni resolución de conflictos, ni conexión — funciona offline por
/// construcción.
///
/// Se persisten bajo [prefijoPreferenciasDispositivo], que es el prefijo que el
/// cierre de sesión respeta. No es un detalle: `cerrarSesion` barre
/// SharedPreferences por descarte, así que una clave fuera de ese prefijo se
/// borraría en cada logout y el usuario tendría que reconfigurar la letra cada
/// turno.
class ServicioPreferenciasUsuario extends ChangeNotifier {
  static const String _claveTipografia =
      '${prefijoPreferenciasDispositivo}tipografia';

  ServicioPreferenciasUsuario({AlmacenPreferencias? almacen})
    : _almacen = almacen ?? const AlmacenPreferenciasCompartidas();

  final AlmacenPreferencias _almacen;

  TamanoTipografia _tipografia = TamanoTipografia.porDefecto;

  /// Última elección pedida por el usuario, aunque su escritura siga en vuelo.
  ///
  /// Sin esto, dos toques seguidos ("Grande" y enseguida "Muy grande") lanzan
  /// dos escrituras que pueden resolverse en cualquier orden: si la primera
  /// termina última, la app queda renderizando "Grande" mientras el radio y lo
  /// guardado dicen "Muy grande", y al reabrir aparece el otro tamaño sin que el
  /// usuario haya hecho nada que lo explique.
  TamanoTipografia _ultimaPedida = TamanoTipografia.porDefecto;

  /// Tamaño de tipografía elegido. Válido desde la construcción: `main` arma el
  /// provider antes de poder esperar a [inicializar], y el primer build no puede
  /// quedarse sin valor.
  TamanoTipografia get tipografia => _tipografia;

  /// Hidrata las preferencias guardadas. Lo que no esté o no se entienda cae en
  /// el valor por defecto (ver [TamanoTipografia.parsear]).
  Future<void> inicializar() async {
    _tipografia = TamanoTipografia.parsear(
      await _almacen.leer(_claveTipografia),
    );
    _ultimaPedida = _tipografia;
    notifyListeners();
  }

  /// Cambia el tamaño de tipografía y lo persiste.
  ///
  /// Notifica sólo si cambió: el `notifyListeners` reconstruye el subárbol de
  /// rutas, así que repetirlo por una elección idéntica es costo puro.
  ///
  /// **Persiste ANTES de mutar el estado en memoria.** Al revés —que es como
  /// sale escribirlo— un fallo aborta con `_tipografia` ya cambiado y sin haber
  /// notificado: la pantalla sigue en la opción vieja y, como la guarda de
  /// igualdad cree que ya está aplicada, volver a tocarla no hace nada. La
  /// opción queda muerta hasta reiniciar.
  ///
  /// Devuelve si quedó guardado, para que la pantalla pueda avisar. Si falla, no
  /// se aplica nada: es preferible que la elección no tome efecto —y se vea— a
  /// que tome efecto y se pierda al reiniciar. [AlmacenPreferencias] ya unifica
  /// las dos formas en que la plataforma falla (devolver `false` y lanzar).
  Future<bool> cambiarTipografia(TamanoTipografia tamano) {
    if (tamano == _tipografia && tamano == _ultimaPedida) {
      return Future<bool>.value(true);
    }
    _ultimaPedida = tamano;

    // Las escrituras se ENCADENAN, no se lanzan en paralelo. Dos toques seguidos
    // —"Grande" y enseguida "Muy grande"— disparan dos escrituras sobre la misma
    // clave; sueltas, pueden resolverse en cualquier orden y el almacén termina
    // con la PRIMERA. Al reabrir, la app aparece con un tamaño que el usuario ya
    // había descartado, sin nada que lo explique. Encadenadas, el orden de
    // llegada al almacén es el orden en que el usuario tocó.
    final resultado = _cola.then((_) => _persistir(tamano));
    _cola = resultado.then((_) {}, onError: (_) {});
    return resultado;
  }

  /// Cola de escrituras. Se descarta el error para que un fallo no envenene la
  /// cadena y bloquee todos los cambios posteriores.
  Future<void> _cola = Future<void>.value();

  Future<bool> _persistir(TamanoTipografia tamano) async {
    // Se captura además de que el almacén ya traduzca sus fallos: si alguna
    // implementación deja escapar una excepción, acá se convierte en un "no se
    // pudo guardar" que la pantalla muestra, en vez de un error asíncrono sin
    // capturar que sólo aparece en la consola.
    bool guardado;
    try {
      guardado = await _almacen.escribir(_claveTipografia, tamano.name);
    } catch (_) {
      guardado = false;
    }
    if (!guardado) return false;

    // Si mientras se escribía el usuario eligió otra cosa, no se aplica ésta:
    // haría parpadear la app hacia un tamaño ya descartado. La escritura de la
    // elección nueva viene detrás en la cola y es la que va a mandar.
    if (_ultimaPedida != tamano || tamano == _tipografia) return true;

    _tipografia = tamano;
    notifyListeners();
    return true;
  }
}
