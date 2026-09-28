import 'package:flutter/foundation.dart';

import '../utils/fecha_recepcion.dart';
import '../utils/ventana_recepciones.dart';

/// Cuántos tramos de 7 días está abierta la pantalla de Recepciones (HU-013).
///
/// Es un controlador diminuto a propósito. Vive a nivel de la app y NO adentro
/// de la pestaña por un motivo concreto: el dashboard destruye la pestaña al
/// cambiar de solapa, así que si el estado viviera ahí la ventana se resetearía
/// a 7 días cada vez que el usuario va a Pedidos y vuelve.
///
/// Y NO se agrega este campo a `ControladorRecibir`: ese controlador lo comparten
/// tres pantallas y notifica en cada tecla del formulario de pedidos, así que
/// meterle esto haría repintar Recepciones mientras alguien tipea una cantidad.
class ControladorVentanaRecepciones extends ChangeNotifier {
  ControladorVentanaRecepciones({DateTime? hoy})
    : _hoy = FechaRecepcion.soloDia(hoy ?? DateTime.now());

  /// Día de referencia, capturado UNA sola vez.
  ///
  /// El PO dijo "usando el calendario del dispositivo, no importa si cambian la
  /// fecha, a no ser que usar otro sea más PERFORMANTE". No hay nada más barato
  /// que leer el reloj local una vez: cualquier alternativa (reloj del servidor)
  /// costaría una llamada de red y rompería el modo offline. Se lee una sola vez
  /// y no en cada fila para que el listado no se evalúe contra dos días
  /// distintos si el refresco cruza la medianoche.
  DateTime _hoy;

  DateTime get hoy => _hoy;

  int _semanas = 1;

  /// Tramos de 7 días abiertos. Arranca en 1 = "los próximos 7 días".
  int get semanas => _semanas;

  /// Último día visible con la ventana actual.
  DateTime get hasta => finDeVentana(hoy: _hoy, semanas: _semanas);

  /// Abre 7 días más. No hay nada que cargar: los pedidos ya están todos en el
  /// dispositivo, así que esto es instantáneo — por eso la pantalla no muestra
  /// ningún spinner, que sería mentir.
  void verMas() {
    _semanas++;
    notifyListeners();
  }

  bool _vencidosExpandidos = false;

  /// ¿La sección "Vencidos" muestra todas o sólo las primeras? (#277)
  ///
  /// Vive ACÁ y no en el `State` de la pestaña por el MISMO motivo que
  /// [semanas], que ya está explicado arriba: el dashboard destruye la pestaña
  /// al cambiar de solapa, así que la sección se volvería a colapsar cada vez
  /// que el usuario va a Pedidos y vuelve —justo después de haberla abierto
  /// para ver qué le debe el proveedor—.
  bool get vencidosExpandidos => _vencidosExpandidos;

  /// Muestra los vencidos que quedaron fuera del tope. Instantáneo y sin
  /// spinner: ya están todos en el dispositivo.
  void expandirVencidos() {
    if (_vencidosExpandidos) return;
    _vencidosExpandidos = true;
    notifyListeners();
  }

  /// Vuelve a los 7 días iniciales.
  void reiniciar() {
    if (_semanas == 1) return;
    _semanas = 1;
    notifyListeners();
  }

  // NOTA: [reiniciar] NO colapsa los vencidos, y es deliberado. Son dos ejes
  // distintos: la ventana mira HACIA ADELANTE (cuántos días se proyectan) y el
  // tope de vencidos mira HACIA ATRÁS (cuántos atrasados se listan). Cerrar la
  // ventana no es motivo para esconderle a alguien los atrasados que acaba de
  // pedir ver.

  /// Reengancha el día de referencia con el reloj.
  ///
  /// La app se deja abierta de un día para el otro: sin esto, "los próximos 7
  /// días" seguiría contando desde ayer y una entrega vencida se vería como si
  /// todavía no hubiera llegado. Lo llama la pantalla al reconstruirse; si el
  /// día no cambió, no notifica nada.
  void sincronizarConElReloj() {
    final ahora = FechaRecepcion.soloDia(DateTime.now());
    if (ahora == _hoy) return;
    _hoy = ahora;
    notifyListeners();
  }
}
