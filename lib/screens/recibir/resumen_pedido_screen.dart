import 'package:flutter/material.dart';
import '../../utils/enlaces_externos.dart';
import '../../theme/insuma_colors.dart';
import '../../services/servicio_envio_pedido.dart';

/// Pantalla de Resumen del pedido (HU-063): muestra proveedor, ítems y cantidades
/// (y el total solo si el usuario puede ver finanzas — HU-060), con un mensaje
/// precargado y EDITABLE y dos canales para enviarlo al proveedor: WhatsApp y,
/// desde #235, el correo (`mailto:` con la app de email predeterminada).
///
/// La lógica de armado de mensaje/URL vive en [ServicioEnvioPedido]; esta vista solo
/// presenta los datos, deja editar el texto y dispara el enlace del canal elegido.
class ResumenPedidoScreen extends StatefulWidget {
  final String proveedorNombre;
  final List<Map<String, dynamic>> items;
  final double total;
  final String? telefonoProveedor;

  /// #235: email del proveedor para el canal de correo. `null` o inválido ⇒
  /// warning + botón de email apagado, mismo trato que el teléfono.
  final String? emailProveedor;
  final bool puedeVerFinanzas;
  final ServicioEnvioPedido servicio;

  /// HU-142: día pedido de recepción. Si viene, se suma al mensaje de WhatsApp.
  final DateTime? fechaRecepcionSolicitada;

  const ResumenPedidoScreen({
    super.key,
    required this.proveedorNombre,
    required this.items,
    required this.total,
    required this.telefonoProveedor,
    this.emailProveedor,
    required this.puedeVerFinanzas,
    required this.servicio,
    this.fechaRecepcionSolicitada,
  });

  @override
  State<ResumenPedidoScreen> createState() => _ResumenPedidoScreenState();
}

class _ResumenPedidoScreenState extends State<ResumenPedidoScreen> {
  late final TextEditingController _mensajeCtrl;
  late final bool _telefonoValido;
  late final bool _emailValido;

  @override
  void initState() {
    super.initState();
    final prep = widget.servicio.prepararResumen(
      proveedorNombre: widget.proveedorNombre,
      items: widget.items,
      telefonoProveedor: widget.telefonoProveedor,
      emailProveedor: widget.emailProveedor,
      fechaRecepcionSolicitada: widget.fechaRecepcionSolicitada,
    );
    _mensajeCtrl = TextEditingController(text: prep.mensaje);
    _telefonoValido = prep.puedeEnviar;
    _emailValido = prep.puedeEnviarEmail;
  }

  @override
  void dispose() {
    _mensajeCtrl.dispose();
    super.dispose();
  }

  /// Arma la URL con el texto ya editado por el usuario y abre WhatsApp.
  ///
  /// #253: si el envío sale bien, cierra el Resumen devolviendo `true` para que
  /// el caller lleve al usuario a Pedidos › Activos. Si falla, se queda acá con
  /// el aviso para reintentar. `navigator` se captura ANTES del await (no se usa
  /// `context` después de un gap asíncrono).
  Future<void> _enviarPorWhatsApp() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final url = widget.servicio.construirUrl(
      telefonoProveedor: widget.telefonoProveedor,
      mensaje: _mensajeCtrl.text,
    );
    if (url == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'El proveedor no tiene un teléfono válido para WhatsApp.',
          ),
        ),
      );
      return;
    }
    // #220: unificado en `EnlacesExternos`.
    if (await EnlacesExternos.abrir(url)) {
      navigator.pop(true);
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
      );
    }
  }

  /// Arma el `mailto:` con el texto ya editado y abre el correo (#235).
  Future<void> _enviarPorEmail() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final url = widget.servicio.construirUrlEmail(
      emailProveedor: widget.emailProveedor,
      mensaje: _mensajeCtrl.text,
    );
    if (url == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('El proveedor no tiene un email válido.')),
      );
      return;
    }
    // Va por `abrirMailto` y no por `abrir`: canLaunchUrl miente para mailto
    // en web y en Android 11+ (ver EnlacesExternos). Por eso el caller muestra
    // una confirmación al volver (#253): en web mailto puede devolver `true`
    // sin abrir nada, y sin ese aviso el salto al inicio parecería que se
    // "comió" el pedido.
    if (await EnlacesExternos.abrirMailto(url)) {
      navigator.pop(true);
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el correo.')),
      );
    }
  }

  String _cantidadStr(num cant) =>
      cant == cant.roundToDouble() ? cant.toInt().toString() : cant.toString();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        title: const Text('Resumen del pedido'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.proveedorNombre,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pedido a enviar al proveedor',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const Divider(height: 24),

          // Detalle de ítems (cantidades, sin precios).
          const Text(
            'Ítems',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 8),
          ...widget.items.map((it) {
            final cant = (it['cantidadPedida'] ?? it['cantidad'] ?? 0) as num;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      it['nombre']?.toString() ?? 'Insumo',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  Text(
                    '${_cantidadStr(cant)} ${it['unidad'] ?? ''}'.trim(),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ],
              ),
            );
          }),

          // Total: solo para quien puede ver finanzas (HU-060).
          if (widget.puedeVerFinanzas) ...[
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Total estimado: \$${widget.total.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ],

          const Divider(height: 24),

          // Mensaje editable de WhatsApp.
          const Text(
            'Mensaje para el proveedor',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _mensajeCtrl,
            maxLines: null,
            minLines: 5,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.all(12),
              helperText: 'Podés editar el texto antes de enviarlo.',
            ),
          ),

          // Warning por canal faltante: cada aviso nombra SU canal y su dato,
          // porque el arreglo es distinto (cargar teléfono vs cargar email).
          if (!_telefonoValido)
            _warningCanal(
              'El proveedor no tiene un teléfono válido. Cargá un número en '
              'su ficha para poder enviar el pedido por WhatsApp.',
            ),
          if (!_emailValido)
            _warningCanal(
              'El proveedor no tiene un email cargado. Cargalo en su ficha '
              'para poder enviar el pedido por correo.',
            ),

          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _telefonoValido ? _enviarPorWhatsApp : null,
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Enviar por WhatsApp'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // #235: el canal alternativo, debajo del principal. Abre la app de
          // correo predeterminada con destinatario, asunto y el MISMO texto
          // editable de arriba. Sin adjuntos: mailto no los permite.
          ElevatedButton.icon(
            onPressed: _emailValido ? _enviarPorEmail : null,
            icon: const Icon(Icons.mail_outline),
            label: const Text('Enviar por email'),
            style: ElevatedButton.styleFrom(
              backgroundColor: InsumaColors.primaryBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// El aviso naranja de canal sin dato de contacto (patrón de HU-063).
  Widget _warningCanal(String texto) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange.shade800,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                texto,
                style: const TextStyle(fontSize: 12, color: Colors.black87),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
