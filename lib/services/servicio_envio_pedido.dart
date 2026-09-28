import '../utils/mensajes_pedido.dart';
import '../utils/validador_datos.dart';

/// Resultado de preparar el resumen de un pedido para enviarlo (HU-063, #235).
/// Lleva el mensaje EDITABLE precargado y una URL lista por canal: `wa.me`
/// para WhatsApp y `mailto:` para el correo — `null` la del canal cuyo dato de
/// contacto falta o no es válido.
class PreparacionEnvioPedido {
  /// Mensaje precargado y editable (ítems + cantidades + pedido de confirmación, sin precios).
  final String mensaje;

  /// Enlace `wa.me` con el mensaje, o `null` si el teléfono del proveedor no es válido.
  final String? urlWhatsApp;

  /// Enlace `mailto:` con asunto y el mensaje como cuerpo, o `null` si el
  /// proveedor no tiene un email válido (#235).
  final String? urlEmail;

  const PreparacionEnvioPedido({
    required this.mensaje,
    required this.urlWhatsApp,
    this.urlEmail,
  });

  /// `true` si hay un teléfono válido y, por lo tanto, se puede ofrecer el envío.
  bool get puedeEnviar => urlWhatsApp != null;

  /// `true` si hay un email válido: el correo es el canal alternativo (#235).
  bool get puedeEnviarEmail => urlEmail != null;
}

/// Servicio de envío de pedidos por WhatsApp (HU-063).
///
/// Encapsula la lógica de armar el mensaje editable y construir el enlace `wa.me`,
/// reutilizando [MensajesPedido] (builder del texto, sin precios — HU-060) y
/// [ValidadorDatos.urlWhatsapp] (normalización del teléfono — HU-047). No accede a
/// la base de datos: la persistencia del estado del pedido la coordina el controlador.
class ServicioEnvioPedido {
  /// Prepara el resumen del pedido: arma el mensaje editable y, si el proveedor tiene
  /// teléfono válido, el enlace `wa.me`. Si no hay teléfono válido, [PreparacionEnvioPedido.puedeEnviar]
  /// devuelve `false` para que la vista muestre el warning y no ofrezca el envío.
  ///
  /// [fechaRecepcionSolicitada] (HU-142) es opcional: si viene, el mensaje
  /// incluye el día en que se necesita la mercadería.
  PreparacionEnvioPedido prepararResumen({
    required String proveedorNombre,
    required List<Map<String, dynamic>> items,
    required String? telefonoProveedor,
    String? emailProveedor,
    DateTime? fechaRecepcionSolicitada,
  }) {
    final mensaje = MensajesPedido.whatsapp(
      proveedorNombre,
      items,
      pedirConfirmacion: true,
      fechaRecepcionSolicitada: fechaRecepcionSolicitada,
    );
    return PreparacionEnvioPedido(
      mensaje: mensaje,
      urlWhatsApp: construirUrl(
        telefonoProveedor: telefonoProveedor,
        mensaje: mensaje,
      ),
      urlEmail: construirUrlEmail(
        emailProveedor: emailProveedor,
        mensaje: mensaje,
      ),
    );
  }

  /// Reconstruye el enlace `wa.me` con el [mensaje] (posiblemente ya editado por el
  /// usuario en el Resumen). Devuelve `null` si el teléfono no es válido.
  String? construirUrl({
    required String? telefonoProveedor,
    required String mensaje,
  }) {
    return ValidadorDatos.urlWhatsapp(
      telefonoProveedor ?? '',
      mensaje: mensaje,
    );
  }

  /// #256: enlace `wa.me` para abrir el chat con el proveedor SIN mensaje
  /// precargado. El icono de mensaje de las tarjetas abría el Resumen (que
  /// REENVÍA el pedido); el PO pidió que sea un contacto directo, con el chat en
  /// blanco. Devuelve `null` si el teléfono no es válido.
  String? construirUrlChatVacio({required String? telefonoProveedor}) {
    return ValidadorDatos.urlWhatsapp(telefonoProveedor ?? '');
  }

  /// Reconstruye el enlace `mailto:` con el [mensaje] (posiblemente ya editado
  /// por el usuario en el Resumen). Devuelve `null` si el email no es válido.
  ///
  /// El asunto es fijo ([MensajesPedido.asuntoEmail]); el cuerpo es el MISMO
  /// texto editable que va por WhatsApp — un solo mensaje, dos canales (#235).
  String? construirUrlEmail({
    required String? emailProveedor,
    required String mensaje,
  }) {
    return ValidadorDatos.urlMailto(
      emailProveedor ?? '',
      asunto: MensajesPedido.asuntoEmail,
      mensaje: mensaje,
    );
  }
}
