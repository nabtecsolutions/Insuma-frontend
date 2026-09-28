import 'fecha_recepcion.dart';

/// Mensajes para compartir pedidos por WhatsApp (HU-011).
class MensajesPedido {
  MensajesPedido._();

  /// Asunto del correo cuando el pedido se manda por email (#235). El CUERPO
  /// no tiene builder propio: es el MISMO texto editable de [whatsapp] — un
  /// solo mensaje, dos canales.
  static const String asuntoEmail = 'Nuevo pedido de insumos';

  /// Arma un mensaje legible para enviarle un pedido al proveedor: lista de ítems
  /// y cantidades, **sin precios** (el precio lo confirma el proveedor; además evita
  /// exponer costos — coherente con HU-060). Cada ítem de [items] trae `nombre`,
  /// `unidad` y `cantidadPedida` (o `cantidad`).
  ///
  /// [pedirConfirmacion] (HU-063): cuando es `true`, agrega un texto solicitando
  /// que el proveedor confirme el pedido. Por defecto es `false` para no alterar el
  /// mensaje original de HU-011.
  ///
  /// [fechaRecepcionSolicitada] (HU-142): día en que se pide recibir la
  /// mercadería. Es OPCIONAL: si es `null` el mensaje sale igual que antes, sin
  /// ninguna línea de fecha.
  static String whatsapp(
    String proveedorNombre,
    List<Map<String, dynamic>> items, {
    bool pedirConfirmacion = false,
    DateTime? fechaRecepcionSolicitada,
  }) {
    final buffer = StringBuffer(
      'Hola $proveedorNombre, quiero hacer el siguiente pedido:\n',
    );
    for (final it in items) {
      final cant = (it['cantidadPedida'] ?? it['cantidad'] ?? 0) as num;
      final cantStr = cant == cant.roundToDouble()
          ? cant.toInt().toString()
          : cant.toString();
      final unidad = (it['unidad'] ?? '').toString();
      final nombre = (it['nombre'] ?? '').toString();
      buffer.writeln('- $cantStr $unidad $nombre'.trim());
    }
    // HU-142: la fecha va DESPUÉS de los ítems y antes del pedido de
    // confirmación, para que lo último que lea el proveedor sea la pregunta.
    if (fechaRecepcionSolicitada != null) {
      buffer.writeln(
        '\nLo necesito para el ${FechaRecepcion.formatear(fechaRecepcionSolicitada)}.',
      );
    }
    if (pedirConfirmacion) {
      buffer.writeln('\n¿Me confirmás disponibilidad y el pedido, por favor?');
    }
    buffer.write('¡Gracias!');
    return buffer.toString();
  }
}
