import 'package:url_launcher/url_launcher.dart';

/// Apertura de enlaces externos (WhatsApp, Mercado Pago, cualquier URL).
///
/// Existe porque el par `canLaunchUrl` / `launchUrl` estaba escrito TRES veces
/// —la ficha del proveedor, el resumen del pedido y el wizard de recurrentes—
/// cada una con su propio manejo del caso "no se pudo abrir". Tres copias de la
/// misma decisión se desincronizan: la que se arregla es siempre una sola.
///
/// NO muestra mensajes ni toca `context`: devuelve si pudo o no, y la pantalla
/// decide cómo avisarlo. Así el módulo no arrastra Flutter ni un `BuildContext`
/// hasta acá abajo.
class EnlacesExternos {
  EnlacesExternos._();

  /// Mercado Pago.
  ///
  /// Es `https://` y no un esquema propio de la app A PROPÓSITO: en Android, si
  /// MP está instalada, el sistema abre la app con este mismo enlace; y en
  /// Flutter Web —donde el PO prueba— abre la pestaña del sitio. Un solo enlace
  /// resuelve las dos plataformas, sin código por plataforma.
  ///
  /// No existe un enlace público de MP que prellene una transferencia, así que
  /// esto es comodidad: el trabajo real lo hacen los botones de copiar el alias
  /// y el CVU.
  static const String mercadoPago = 'https://www.mercadopago.com.ar';

  /// Abre [url] fuera de la app. Devuelve `false` si el sistema no puede.
  ///
  /// `externalApplication` y no el navegador embebido: la gracia es justamente
  /// salir a la app que corresponda (WhatsApp, Mercado Pago, el visor de PDF).
  static Future<bool> abrir(String url) async {
    final uri = Uri.tryParse(url);
    // `Uri.tryParse` es tolerante y casi nunca devuelve null, así que se exige
    // además que tenga esquema: sin esto, un texto suelto se "parsearía" bien y
    // fallaría recién al intentar abrirlo.
    if (uri == null || !uri.hasScheme) return false;
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Abre Mercado Pago. Atajo con nombre, para que las pantallas no repitan la
  /// URL y se pueda cambiar en un solo lugar.
  static Future<bool> abrirMercadoPago() => abrir(mercadoPago);

  /// Abre el cliente de correo con un enlace `mailto:` (#235).
  ///
  /// NO pasa por [abrir] a propósito: `canLaunchUrl` MIENTE para `mailto:` —
  /// en Flutter Web devuelve `false` siempre, y en Android 11+ también, salvo
  /// que el manifest declare `<queries>` para el esquema—. Acá se valida el
  /// esquema y se lanza directo; si el sistema no tiene cliente de correo, el
  /// intento devuelve `false` o lanza, y las dos cosas se traducen a `false`.
  ///
  /// `platformDefault` y no `externalApplication`: en web el navegador es
  /// quien sabe delegar `mailto:` al cliente configurado (Gmail, Outlook…);
  /// en Android el default ya es salir a la app de correo.
  static Future<bool> abrirMailto(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'mailto') return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (_) {
      return false;
    }
  }
}
