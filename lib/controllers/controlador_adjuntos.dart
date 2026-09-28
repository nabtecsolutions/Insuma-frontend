import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../services/servicio_adjuntos.dart';
import '../utils/adjuntos/contenido_archivo.dart';
import '../utils/adjuntos/selector_archivos.dart';
import '../utils/adjuntos/tipo_adjunto.dart';

/// Par contenido staged → adjunto persistido (resultado de [ControladorAdjuntos.persistirEn]).
class AdjuntoCreado {
  final ContenidoArchivo contenido;
  final Adjunto adjunto;
  const AdjuntoCreado({required this.contenido, required this.adjunto});
}

/// Controlador de los adjuntos (remitos) de una recepción en curso (HU-066).
///
/// Mantiene los archivos elegidos *staged* EN MEMORIA hasta que la recepción se
/// confirma: la recepción se persiste recién al "Confirmar", así que los adjuntos se
/// guardan junto con ella (ver [persistirEn]). Orquesta interfaces ([SelectorArchivos]
/// y [ServicioAdjuntos]); NO toca la base de datos ni (de)codifica bytes.
class ControladorAdjuntos extends ChangeNotifier {
  final SelectorArchivos _selector;
  final ServicioAdjuntos _servicio;

  ControladorAdjuntos(this._selector, this._servicio);

  final List<ContenidoArchivo> _pendientes = [];
  String? _error;

  /// Los pendientes ya validados y comprimidos, en el MISMO orden (#227).
  ///
  /// Se llena con [prepararTodo], antes de abrir la transacción, y se consume en
  /// [persistirEn]. Vacío = todavía no se preparó nada; cualquier cambio en la
  /// lista staged lo invalida, para que no se escriba un archivo que ya no es el
  /// que el usuario ve.
  final List<ContenidoArchivo> _preparados = [];

  /// Archivos elegidos aún no persistidos (preview en la UI).
  List<ContenidoArchivo> get pendientes => List.unmodifiable(_pendientes);

  /// Último error de validación (tipo/tamaño), o null.
  String? get error => _error;

  bool get tieneAdjuntos => _pendientes.isNotEmpty;

  /// Abre el selector del sistema y agrega el archivo elegido a la lista staged.
  /// Valida SIEMPRE a través del servicio (la regla de negocio no se duplica acá).
  Future<void> agregarDesdeSelector() async {
    _error = null;
    final contenido = await _selector.elegirArchivo();
    if (contenido == null) {
      // Cancelado por el usuario: no es error.
      notifyListeners();
      return;
    }
    final error = _servicio.validar(contenido);
    if (error != null) {
      _error = error;
      notifyListeners();
      return;
    }
    _pendientes.add(contenido);
    _preparados.clear(); // cambió la lista: lo preparado ya no le corresponde
    notifyListeners();
  }

  /// Quita un archivo staged por índice.
  void quitar(int indice) {
    if (indice >= 0 && indice < _pendientes.length) {
      _pendientes.removeAt(indice);
      _preparados.clear();
      notifyListeners();
    }
  }

  /// Valida y comprime TODO lo staged, sin tocar la base (#227).
  ///
  /// Devuelve `null` si quedó todo listo, o el mensaje del primer archivo que no
  /// pasa — listo para mostrar. Se corre ANTES de registrar la recepción: así lo
  /// que puede fallar por el archivo falla con cero filas escritas y con los
  /// pendientes intactos, en vez de reventar a mitad de una transacción o, peor,
  /// de descartarse en silencio después de que la recepción ya se guardó.
  ///
  /// Los archivos se preparan de a uno y no en paralelo: comprimir varias
  /// imágenes a la vez en un teléfono de cocina es pelear por la misma CPU, y en
  /// Flutter Web —sin isolates— directamente se serializa igual pero peor.
  Future<String?> prepararTodo() async {
    _preparados.clear();
    for (final contenido in _pendientes) {
      try {
        _preparados.add(await _servicio.preparar(contenido));
      } on AdjuntoInvalidoException catch (e) {
        _preparados.clear();
        _error = e.mensaje;
        notifyListeners();
        return e.mensaje;
      }
    }
    return null;
  }

  /// Persiste todos los archivos staged contra [recepcionId]. Lo invoca HU-064 tras
  /// crear la recepción; idealmente DENTRO de la misma transacción Drift de la
  /// recepción (las escrituras se enrolan en la transacción ambiente de [db]) para
  /// que una recepción "Recibido" sin comprobante no pase inadvertida. Desde
  /// #226 vuelve a BLOQUEAR el cierre (`validarRecepcion`), aunque esa regla
  /// mira los pendientes en memoria y no lo que llegó a persistirse: #227.
  /// Devuelve pares contenido staged → adjunto creado (HU-144 necesita la
  /// IDENTIDAD para persistir el resultado OCR sobre el adjunto escaneado —
  /// "el primero" no alcanza: puede haber PDFs antes o `adjuntar` fallidos que
  /// corren los índices).
  Future<List<AdjuntoCreado>> persistirEn({
    required String negocioId,
    String? recepcionId,
    String? pagoId,
    String tipo = TipoAdjunto.remito,
  }) async {
    // #238: exactamente-uno. La guarda de fondo vive en el repositorio; acá se
    // repite para que el error salte ANTES de escribir el primer archivo de
    // una tanda (y no a mitad, dejando persistidos algunos).
    if ((recepcionId == null) == (pagoId == null)) {
      throw ArgumentError(
        'persistirEn requiere recepcionId O pagoId (exactamente uno).',
      );
    }
    if (_preparados.length != _pendientes.length) {
      // Defensa, no cortesía: sin `prepararTodo` esto compilaría igual y
      // volvería a comprimir dentro de la transacción, que es justo lo que #227
      // saca de ahí. Falla ruidoso en desarrollo y tiene su test.
      throw StateError(
        'persistirEn requiere prepararTodo() antes: hay '
        '${_pendientes.length} archivo(s) staged y ${_preparados.length} '
        'preparado(s).',
      );
    }
    // Sin `if (adjunto != null)`, y no por descuido: `guardarPreparado` devuelve
    // `Future<Adjunto>` NO nullable — si la escritura falla, LANZA. El `null`
    // que el bucle viejo salteaba en silencio sólo venía de las validaciones de
    // `adjuntar`, que ahora corren antes en `prepararTodo`. O sea: acá ya no
    // queda ningún fallo que ignorar, y el que hay sube y revierte.
    final creados = <AdjuntoCreado>[];
    for (var i = 0; i < _preparados.length; i++) {
      final adjunto = await _servicio.guardarPreparado(
        _preparados[i],
        negocioId: negocioId,
        recepcionId: recepcionId,
        pagoId: pagoId,
        tipo: tipo,
      );
      // La IDENTIDAD que se devuelve es la del contenido STAGED, no la del
      // comprimido: `identical(creado.contenido, archivoEscaneado)` es lo único
      // que casa el resultado del OCR con su adjunto (HU-144), y romperlo haría
      // que el escaneo dejara de guardarse sin una sola señal.
      creados.add(AdjuntoCreado(contenido: _pendientes[i], adjunto: adjunto));
    }
    _pendientes.clear();
    _preparados.clear();
    notifyListeners();
    return creados;
  }

  /// Limpia el estado (al cerrar/cancelar la recepción).
  void limpiar() {
    _pendientes.clear();
    _error = null;
    notifyListeners();
  }
}
