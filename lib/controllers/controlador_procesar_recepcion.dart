import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../models/recepcion_facturable.dart';
import '../services/servicio_ocr_remito.dart';
import '../services/servicio_procesar_recepcion.dart';
import '../utils/desenlace_recepcion.dart';
import '../services/servicio_precios.dart';
import '../utils/iva.dart';
import '../utils/origen_precio.dart';
import '../utils/adjuntos/contenido_archivo.dart';
import '../utils/sanitizador_texto.dart';
import 'controlador_adjuntos.dart';

/// Un renglón de la pantalla: lo recibido de UN insumo, esperando su costo.
///
/// Es la versión EDITABLE de [LineaCosto]: la cantidad viene fija de la
/// recepción y el usuario carga el neto (por unitario o por total de línea) y
/// elige la alícuota. Toda la aritmética delega en `utils/iva.dart` — acá solo
/// vive el estado de edición.
class LineaCostoEditable {
  final String insumoId;
  final String nombre;
  final String unidad;

  /// Cantidad ACEPTADA en la recepción. Fija: lo que se carga acá es el precio.
  final double cantidad;

  /// Precio neto de una unidad. `null` = todavía sin cargar (y el paso 2 no
  /// deja avanzar); nunca se convierte en 0 silencioso.
  double? netoUnitario;

  /// Alícuota en FRACCIÓN, siempre una de [alicuotas].
  double alicuota;

  /// Cómo prefiere cargar esta línea el usuario: false = unitario (el default
  /// del PO), true = total de la línea (y el unitario se deriva).
  bool cargaPorTotal;

  /// Trazabilidad HU-144: `compra_ocr` si el neto vino sugerido por el escaneo
  /// y no se editó; `compra_manual` en cuanto alguien lo toca.
  String origenPrecio;

  LineaCostoEditable({
    required this.insumoId,
    required this.nombre,
    required this.unidad,
    required this.cantidad,
    this.netoUnitario,
    this.alicuota = alicuotaPorDefecto,
    this.cargaPorTotal = false,
    this.origenPrecio = OrigenPrecio.compraManual,
  });

  bool get completa => (netoUnitario ?? 0) > 0;

  /// La línea como la entiende el módulo de IVA (con 0 si falta el neto, para
  /// que el pie pueda mostrarse mientras se carga).
  LineaCosto get comoLineaCosto => LineaCosto(
    insumoId: insumoId,
    netoUnitario: netoUnitario ?? 0,
    cantidad: cantidad,
    alicuota: alicuota,
  );
}

/// Estado y orquestación de la pantalla "Procesar recepción" (#229).
///
/// El dato del wizard vive COMPLETO acá y no en los widgets de cada paso: es lo
/// que hace que lo tipeado sobreviva al cambio de slide (los slides de un PageView
/// se desmontan). Mismo patrón que `ControladorPedidoRecurrente`.
///
/// Sin lógica de negocio: la aritmética es de `utils/iva.dart` y la
/// persistencia entera —factura, renglones, costeo, pago, estado del pedido—
/// es de [ServicioProcesarRecepcion]. Lo que sí es de acá: validación de
/// pantalla (qué apaga el botón) y el armado de la llamada.
class ControladorProcesarRecepcion extends ChangeNotifier {
  final ServicioProcesarRecepcion _servicio;
  final RecepcionFacturable recepcion;
  final String negocioId;

  /// ¿Es la última recepción del pedido sin factura? Gobierna
  /// `marcarPedidoFacturado`: marcar antes de tiempo esconde para siempre las
  /// recepciones parciales que faltan procesar (el filtro de históricos las
  /// leería como efectivo viejo).
  final bool esUltimaRecepcionDelPedido;

  /// Facturas ya registradas del negocio, para el control de número duplicado
  /// por proveedor (mudado de `ControladorPagos.registrarFacturaDeRecepcion`).
  final List<Factura> _facturasExistentes;

  final String? _usuarioId;

  /// HU-144: motor de sugerencias. Null (o no disponible en la plataforma) ⇒
  /// el botón "Escanear factura" no se muestra y el flujo es idéntico.
  final ServicioOcrRemito? _servicioOcr;

  ControladorProcesarRecepcion(
    this._servicio, {
    required this.recepcion,
    required this.negocioId,
    required this.esUltimaRecepcionDelPedido,
    required this._facturasExistentes,
    this._usuarioId,
    this._servicioOcr,
    // #243: último ingreso real por insumo (precio + alícuota), resuelto por
    // `ingresosPreviosDe` ANTES de abrir la pantalla. Vacío ⇒ todo nace como
    // antes (costo a tipear, alícuota default).
    Map<String, ({double precio, double alicuota})> ingresosPrevios = const {},
  }) : pagadoEnEfectivo = recepcion.esEfectivo,
       // A7: el total manual de HU-143 ("Editar total" / el escrito al
       // recibir) precarga el del paso 3.
       totalManual = recepcion.recepcion.totalRecibido {
    final items = _itemsDe(recepcion);
    lineas = [
      for (final it in items)
        if (DesenlaceRecepcion.aceptadaDeLinea(it) > 0)
          _lineaSembrada(it, ingresosPrevios),
    ];
  }

  /// #243: la línea nace sembrada con la última compra REAL del insumo a este
  /// proveedor — la misma autoridad que el "Últ. compra" de la ficha (#242),
  /// para que no existan dos verdades. Clave ausente ⇒ costo a tipear y
  /// alícuota default, como siempre (decisión del PO: sin compra previa a ESE
  /// proveedor no se inventa). Una alícuota legacy fuera de escala cae al
  /// default. La siembra queda `compra_manual`: aceptarla sin tocar es
  /// confirmar ese valor real; el escaneo OCR posterior la pisa, y la edición
  /// manual pisa a ambos.
  static LineaCostoEditable _lineaSembrada(
    Map<String, dynamic> it,
    Map<String, ({double precio, double alicuota})> previos,
  ) {
    final insumoId = (it['insumoId'] ?? '').toString();
    final previo = previos[insumoId];
    return LineaCostoEditable(
      insumoId: insumoId,
      nombre: (it['nombre'] ?? 'Insumo').toString(),
      unidad: (it['unidad'] ?? '').toString(),
      cantidad: DesenlaceRecepcion.aceptadaDeLinea(it),
      netoUnitario: previo?.precio,
      alicuota: previo != null && esAlicuotaValida(previo.alicuota)
          ? previo.alicuota
          : alicuotaPorDefecto,
    );
  }

  /// #243: resuelve el mapa de la siembra ANTES de construir el controlador.
  ///
  /// Vive acá —y no en la pantalla— porque requiere saber parsear los items de
  /// la recepción, que es conocimiento de este controlador. Sin proveedor
  /// identificado no hay a quién preguntarle: mapa vacío (decisión del PO).
  static Future<Map<String, ({double precio, double alicuota})>>
  ingresosPreviosDe(
    ServicioPrecios precios,
    RecepcionFacturable recepcion,
  ) async {
    final proveedorId = recepcion.proveedorId;
    if (proveedorId == null) return const {};
    final ids = {
      for (final it in _itemsDe(recepcion))
        if (DesenlaceRecepcion.aceptadaDeLinea(it) > 0)
          (it['insumoId'] ?? '').toString(),
    }..remove('');
    if (ids.isEmpty) return const {};
    return precios.ultimoIngresoPorInsumo(
      proveedorId: proveedorId,
      insumosIds: ids,
    );
  }

  static List<Map<String, dynamic>> _itemsDe(RecepcionFacturable recepcion) {
    try {
      return (jsonDecode(recepcion.recepcion.items) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  // ── Estado del wizard ──────────────────────────────────────────────────────

  late final List<LineaCostoEditable> lineas;

  String numeroFactura = '';
  DateTime fechaVencimiento = DateTime.now().add(const Duration(days: 30));
  String comentario = '';

  /// HU-143: si está, PISA el total de la factura (la deuda), nunca el costeo.
  double? totalManual;

  /// Editable por el admin (decisión del PO, 2026-08-27): puede corregir lo
  /// que el cocinero marcó (o se olvidó de marcar) al recibir, contra el
  /// comprobante. Arranca en la marca del pedido.
  bool pagadoEnEfectivo;

  bool procesando = false;

  // ── Derivados para la vista ────────────────────────────────────────────────

  /// Los tres números del pie, siempre calculables (líneas sin neto valen 0).
  ResumenIva get resumen =>
      ResumenIva.de([for (final l in lineas) l.comoLineaCosto]);

  /// Lo que se le va a deber (o se le pagó) al proveedor.
  double get totalFactura => totalManual ?? resumen.total;

  /// En efectivo el proveedor suele no dar factura: el número es opcional y,
  /// vacío, nace como `S/F <recepción>` (lo arma el Service).
  bool get numeroEsOpcional => pagadoEnEfectivo;

  // ── Mutadores (notifican: el pie y la botonera reaccionan) ────────────────

  void cambiarNumero(String v) {
    numeroFactura = v;
    notifyListeners();
  }

  void cambiarVencimiento(DateTime v) {
    fechaVencimiento = v;
    notifyListeners();
  }

  void cambiarComentario(String v) {
    comentario = v;
    notifyListeners();
  }

  void cambiarTotalManual(double? v) {
    totalManual = v;
    notifyListeners();
  }

  void cambiarPagadoEnEfectivo(bool v) {
    pagadoEnEfectivo = v;
    notifyListeners();
  }

  /// Carga el NETO UNITARIO de una línea (el modo por defecto).
  void cambiarNetoUnitario(LineaCostoEditable linea, double? v) {
    linea.netoUnitario = v;
    linea.origenPrecio = OrigenPrecio.compraManual;
    notifyListeners();
  }

  /// Carga el TOTAL NETO de la línea y deriva el unitario (la otra mitad de la
  /// conversión que pidió el PO). La división vive en `utils/iva.dart`.
  void cambiarTotalNetoLinea(LineaCostoEditable linea, double? v) {
    linea.netoUnitario = v == null
        ? null
        : unitarioDesdeTotal(v, linea.cantidad);
    linea.origenPrecio = OrigenPrecio.compraManual;
    notifyListeners();
  }

  void cambiarAlicuota(LineaCostoEditable linea, double v) {
    linea.alicuota = v;
    notifyListeners();
  }

  void cambiarModoCarga(LineaCostoEditable linea, bool porTotal) {
    linea.cargaPorTotal = porTotal;
    notifyListeners();
  }

  // ── El escaneo (HU-144, mudado de la recepción en #229) ───────────────────

  /// ¿Se muestra el botón "Escanear factura"? Sin motor en la plataforma (web,
  /// Windows) el flujo manual es idéntico.
  bool get puedeEscanear => _servicioOcr?.disponible ?? false;

  bool escaneando = false;

  /// Mensaje del último intento de escaneo (falta de foto, sin reconocer).
  String? avisoOcr;

  /// Contador de escaneos: entra en la ValueKey de los campos del paso 2 para
  /// que un RE-escaneo los reconstruya con el valor nuevo (`valorInicial` sólo
  /// aplica en el primer build del elemento).
  int escaneos = 0;

  /// El resultado listo para persistir al finalizar, y la IDENTIDAD del
  /// archivo escaneado (para pegarle la evidencia al adjunto correcto y no a
  /// otro — mismo criterio que tenía la recepción).
  String? _datosOcrJson;
  ContenidoArchivo? _archivoEscaneado;

  /// Reconoce la primera IMAGEN staged de [comprobantes] y precarga los costos.
  ///
  /// El precio del papel se trata como NETO: es la continuidad de HU-144 (el
  /// precio del remito iba directo al historial sin descontar IVA), así los
  /// números no saltan de escala el día del deploy. La alícuota queda en la
  /// elegida (21% por defecto), editable. Si la persona edita el neto, el
  /// origen vuelve a `compra_manual` (patrón de siempre).
  Future<void> escanearFactura(ControladorAdjuntos comprobantes) async {
    final servicio = _servicioOcr;
    if (servicio == null || escaneando) return;
    final imagen = comprobantes.pendientes
        .where((c) => c.mimeType.startsWith('image/'))
        .firstOrNull;
    if (imagen == null) {
      avisoOcr =
          'Adjuntá primero una FOTO de la factura en el paso 1 (el escaneo '
          'no lee PDF).';
      notifyListeners();
      return;
    }
    escaneando = true;
    avisoOcr = null;
    notifyListeners();

    final resultado = await servicio.analizar(
      archivo: imagen,
      itemsPedido: [
        for (final l in lineas) {'insumoId': l.insumoId, 'nombre': l.nombre},
      ],
    );

    escaneando = false;
    if (resultado == null) {
      avisoOcr =
          'No se pudo reconocer la factura: cargá los costos a mano como '
          'siempre.';
      notifyListeners();
      return;
    }
    for (final l in lineas) {
      final sugerencia = resultado.sugerencias.porInsumo[l.insumoId];
      if (sugerencia == null) continue;
      l.netoUnitario = sugerencia.precioUnitario;
      l.origenPrecio = OrigenPrecio.compraOcr;
    }
    // Total detectado → precarga el total manual (HU-143), editable.
    final total = resultado.sugerencias.totalDetectado;
    if (total != null) totalManual = total;
    _datosOcrJson = resultado.datos.serializar();
    _archivoEscaneado = imagen;
    escaneos++;
    notifyListeners();
  }

  // ── Validación de pantalla ────────────────────────────────────────────────

  /// Por qué no se puede avanzar desde [paso], o `null` si se puede. Es lo que
  /// apaga el botón "Siguiente"/"Finalizar" — la validación de NEGOCIO la
  /// repite el Service, que no confía en la pantalla.
  String? motivoBloqueo(int paso) {
    switch (paso) {
      case 0:
        final numero = SanitizadorTexto.limpiar(numeroFactura);
        if (numero.isEmpty && !numeroEsOpcional) {
          return 'Ingresá el número de factura (en efectivo es opcional).';
        }
        if (numero.isNotEmpty && _numeroDuplicado(numero)) {
          return 'Ya existe una factura con ese número para este proveedor.';
        }
        return null;
      case 1:
        if (lineas.isEmpty) {
          return 'La recepción no tiene ítems aceptados para costear.';
        }
        final sinCosto = lineas.where((l) => !l.completa).length;
        if (sinCosto > 0) {
          return sinCosto == 1
              ? 'Falta el costo de 1 insumo.'
              : 'Falta el costo de $sinCosto insumos.';
        }
        return null;
      default:
        if (pagadoEnEfectivo && recepcion.proveedorId == null) {
          // Sin proveedor no hay a quién asentarle el pago: la factura
          // quedaría 'facturada sin pago' para siempre, invisible en la lista.
          return 'No se pudo identificar al proveedor: registralo antes de '
              'procesar un pago en efectivo.';
        }
        if (totalFactura <= 0) {
          return 'El total de la factura debe ser mayor a cero.';
        }
        return null;
    }
  }

  bool _numeroDuplicado(String numero) => _facturasExistentes.any(
    (f) =>
        f.proveedorId == recepcion.proveedorId &&
        f.numeroFactura.trim().toLowerCase() == numero.toLowerCase(),
  );

  // ── El final ──────────────────────────────────────────────────────────────

  /// Procesa la recepción y persiste los comprobantes staged. Devuelve `null`
  /// si salió bien o un mensaje de error listo para mostrar.
  Future<String?> finalizar(ControladorAdjuntos? comprobantes) async {
    for (var paso = 0; paso <= 2; paso++) {
      final motivo = motivoBloqueo(paso);
      if (motivo != null) return motivo;
    }
    if (procesando) return null; // doble tap: la primera llamada sigue en vuelo

    // #227: lo que puede fallar por el archivo falla ANTES de escribir nada.
    if (comprobantes != null && comprobantes.tieneAdjuntos) {
      final errorAdjunto = await comprobantes.prepararTodo();
      if (errorAdjunto != null) return errorAdjunto;
    }

    procesando = true;
    notifyListeners();

    try {
      // Los adjuntos creados dentro de la transacción, capturados para casar el
      // OCR después (afuera). Si la transacción revierte, esta lista no se usa.
      final creados = <AdjuntoCreado>[];
      final numero = SanitizadorTexto.limpiar(numeroFactura);
      final nota = SanitizadorTexto.limpiarMultilinea(comentario);
      await _servicio.procesar(
        negocioId: negocioId,
        recepcionId: recepcion.recepcionId,
        pedidoId: recepcion.pedidoId,
        proveedorId: recepcion.proveedorId,
        lineas: [for (final l in lineas) l.comoLineaCosto],
        fechaVencimiento: fechaVencimiento,
        numeroFactura: numero.isEmpty ? null : numero,
        totalManual: totalManual,
        pagadoEnEfectivo: pagadoEnEfectivo,
        // La fecha de la PLATA es la de la recepción (cuando salió), no la de
        // hoy (cuando el admin la carga).
        fechaRecepcion: recepcion.fechaRecepcion,
        marcarPedidoFacturado: esUltimaRecepcionDelPedido,
        // HU-144: por línea — compra_ocr si la sugerencia quedó intacta,
        // compra_manual en cuanto alguien la tocó.
        origenPorInsumo: {for (final l in lineas) l.insumoId: l.origenPrecio},
        comentario: nota.isEmpty ? null : nota,
        usuarioId: _usuarioId,
        // #227: el comprobante se escribe DENTRO de la transacción del
        // procesamiento. Si falla, se revierten factura, renglones, costeo,
        // pago y el estado del pedido — antes quedaba todo asentado y el
        // archivo se descartaba en silencio, y reintentar generaba una SEGUNDA
        // factura con su segundo débito.
        adjuntarEnTransaccion:
            (comprobantes != null && comprobantes.tieneAdjuntos)
            ? () async {
                creados.addAll(
                  await comprobantes.persistirEn(
                    negocioId: negocioId,
                    // Recepción↔factura 1:1 por HU-067: el adjunto cuelga de
                    // la MISMA recepción.
                    recepcionId: recepcion.recepcionId,
                    // #238: el tipo dice lo que el papel ES — factura en
                    // transferencia, comprobante solo si hubo pago (efectivo).
                    // La regla vive en el Service.
                    tipo: ServicioProcesarRecepcion.tipoAdjuntoRecepcion(
                      pagadoEnEfectivo: pagadoEnEfectivo,
                    ),
                  ),
                );
              }
            : null,
      );

      // HU-144: la evidencia del escaneo se pega al adjunto CUYA IDENTIDAD
      // coincide con el archivo escaneado (puede no ser el primero: puede
      // haber PDFs antes). Si la persona lo quitó tras escanear, el OCR
      // simplemente no se guarda — jamás se pega a otro adjunto.
      //
      // Corre FUERA de la transacción a propósito: `guardarResultado` es
      // best-effort por diseño (se traga sus errores, el escaneo se puede
      // repetir) y meterlo adentro sumaría una superficie de rollback que
      // nadie pidió — perder una factura entera por un JSON de OCR sería peor
      // que perder el OCR.
      if (_datosOcrJson != null && _archivoEscaneado != null) {
        for (final creado in creados) {
          if (identical(creado.contenido, _archivoEscaneado)) {
            await _servicioOcr?.guardarResultado(
              adjuntoId: creado.adjunto.id,
              datosOcrJson: _datosOcrJson!,
            );
            break;
          }
        }
      }
      return null;
    } on ArgumentError catch (e) {
      return e.message?.toString() ?? 'No se pudo procesar la recepción.';
    } catch (_) {
      return 'No se pudo procesar la recepción. Intentá de nuevo.';
    } finally {
      procesando = false;
      notifyListeners();
    }
  }
}
