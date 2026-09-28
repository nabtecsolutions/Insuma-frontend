/// Clase que contiene metodos utilitarios de validacion de datos.
class ValidadorDatos {
  /// Valida que el formato del CUIT argentino sea de exactamente 11 digitos numericos y estructura valida.
  static bool validarCuit(String cuit) {
    final limpio = cuit.replaceAll(RegExp(r'[-\s]'), '');
    if (limpio.length != 11 || double.tryParse(limpio) == null) {
      return false;
    }

    // Verificacion del digito verificador del CUIT argentino (Algoritmo Modulo 11)
    final factores = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];
    int suma = 0;
    for (int i = 0; i < 10; i++) {
      suma += int.parse(limpio[i]) * factores[i];
    }

    final digitoVerificadorCalculado = 11 - (suma % 11);
    final digitoReal = int.parse(limpio[10]);

    if (digitoVerificadorCalculado == 11) {
      return digitoReal == 0;
    } else if (digitoVerificadorCalculado == 10) {
      return false;
    } else {
      return digitoReal == digitoVerificadorCalculado;
    }
  }

  /// Valida que el formato de CBU o CVU sea de exactamente 22 digitos numericos.
  static bool validarCbuCvu(String cbu) {
    final limpio = cbu.replaceAll(RegExp(r'[-\s]'), '');
    if (limpio.length != 22 || double.tryParse(limpio) == null) {
      return false;
    }
    return true;
  }

  /// Valida que el correo electronico tenga una estructura basica aceptable.
  static bool validarEmail(String email) {
    final regex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
    return regex.hasMatch(email);
  }

  /// Valida un telefono (HU-057): al menos 6 digitos, permitiendo el formato
  /// habitual con +, espacios, guiones y parentesis.
  static bool validarTelefono(String telefono) {
    final limpio = telefono.replaceAll(RegExp(r'[\s\-()+]'), '');
    return RegExp(r'^\d{6,}$').hasMatch(limpio);
  }

  /// Construye el enlace wa.me para contactar por WhatsApp (HU-047), normalizando
  /// el telefono a digitos. [mensaje] opcional se pre-carga en el chat (reutilizable
  /// por HU-011 para compartir un pedido). Devuelve null si el numero no es valido.
  static String? urlWhatsapp(String telefono, {String? mensaje}) {
    if (!validarTelefono(telefono)) return null;
    final digitos = telefono.replaceAll(RegExp(r'\D'), '');
    final base = 'https://wa.me/$digitos';
    if (mensaje == null || mensaje.isEmpty) return base;
    return '$base?text=${Uri.encodeComponent(mensaje)}';
  }

  /// Construye el enlace `mailto:` para enviar el pedido por correo (#235).
  /// Devuelve null si el email no es valido.
  ///
  /// La query se arma A MANO con [Uri.encodeComponent] y no con
  /// `Uri(queryParameters:)`: ese constructor codifica el espacio como `+`
  /// (form-encoding), y los clientes de correo lo muestran LITERAL en el
  /// asunto y el cuerpo — "Hola+quiero+hacer+un+pedido". El email va sin
  /// codificar: ya pasó [validarEmail] y codificar la arroba confunde a
  /// algunos clientes.
  static String? urlMailto(String email, {String? asunto, String? mensaje}) {
    final destinatario = email.trim();
    if (!validarEmail(destinatario)) return null;
    final params = <String>[
      if (asunto != null && asunto.isNotEmpty)
        'subject=${Uri.encodeComponent(asunto)}',
      if (mensaje != null && mensaje.isNotEmpty)
        'body=${Uri.encodeComponent(mensaje)}',
    ];
    final base = 'mailto:$destinatario';
    if (params.isEmpty) return base;
    return '$base?${params.join('&')}';
  }

  // ---------------------------------------------------------------------------
  // NUMEROS (HU-137)
  //
  // Hasta esta HU la app leia los campos numericos con `double.tryParse(v) ?? 0.0`:
  // tipear "abc" en Monto guardaba 0 en silencio, y "12,5" (como se escribe un
  // precio en Argentina) tambien guardaba 0. Estos metodos son la unica fuente de
  // verdad para interpretar lo que el usuario escribio, y devuelven null cuando el
  // texto NO es un numero, para que el formulario pueda rechazarlo en vez de
  // inventar un cero.
  // ---------------------------------------------------------------------------

  /// Interpreta [texto] como numero aceptando coma O punto como separador decimal.
  /// Devuelve `null` si el texto esta vacio o no es un numero valido.
  ///
  /// Reglas de desambiguacion (formato es-AR y en-US conviven en el mismo campo):
  ///  - `"12,5"` y `"12.5"` -> 12.5 (un solo separador = decimal);
  ///  - `"1.234,56"` / `"1,234.56"` -> 1234.56 (con ambos, el ULTIMO es el decimal
  ///    y el otro es separador de miles);
  ///  - `"1.234.567"` -> 1234567 (el separador repetido solo puede ser de miles);
  ///  - se ignoran espacios y el simbolo de moneda.
  static double? parsearNumero(String? texto) {
    if (texto == null) return null;
    var limpio = texto.replaceAll(RegExp(r'[\s$]'), '');
    if (limpio.isEmpty) return null;

    final puntos = '.'.allMatches(limpio).length;
    final comas = ','.allMatches(limpio).length;

    if (puntos > 0 && comas > 0) {
      // El separador decimal es el que aparece mas a la derecha.
      final decimal = limpio.lastIndexOf('.') > limpio.lastIndexOf(',')
          ? '.'
          : ',';
      final miles = decimal == '.' ? ',' : '.';
      limpio = limpio.replaceAll(miles, '').replaceAll(decimal, '.');
    } else if (comas > 0) {
      // Repetido solo puede ser separador de miles; una sola coma es decimal.
      limpio = comas > 1
          ? limpio.replaceAll(',', '')
          : limpio.replaceAll(',', '.');
    } else if (puntos > 1) {
      limpio = limpio.replaceAll('.', '');
    }

    // Rechaza cualquier resto no numerico (letras, simbolos, signos intercalados).
    if (!RegExp(r'^-?\d*\.?\d+$').hasMatch(limpio)) return null;
    return double.tryParse(limpio);
  }

  /// ¿[texto] es un numero interpretable? (no dice nada sobre su signo)
  static bool esNumeroValido(String? texto) => parsearNumero(texto) != null;

  /// Valida un numero mayor a cero (cantidades, precios, montos). Con
  /// [permitirCero] en true acepta el cero pero sigue rechazando negativos y basura.
  static bool validarNumeroPositivo(
    String? texto, {
    bool permitirCero = false,
  }) {
    final valor = parsearNumero(texto);
    if (valor == null) return false;
    return permitirCero ? valor >= 0 : valor > 0;
  }

  /// Valida un entero dentro de un rango opcional (porciones, minutos, dias).
  static bool validarEntero(String? texto, {int? min, int? max}) {
    final valor = parsearNumero(texto);
    if (valor == null || valor != valor.roundToDouble()) return false;
    final entero = valor.toInt();
    if (min != null && entero < min) return false;
    if (max != null && entero > max) return false;
    return true;
  }

  /// Valida un identificador ALFANUMERICO de negocio (numero de factura, remito,
  /// referencia de pago): letras, digitos y los separadores habituales
  /// (espacio, guion, guion bajo, barra, punto y numeral). Sin simbolos raros.
  static bool validarAlfanumerico(
    String? texto, {
    int minLongitud = 1,
    int maxLongitud = 60,
  }) {
    final limpio = (texto ?? '').trim();
    if (limpio.length < minLongitud || limpio.length > maxLongitud) {
      return false;
    }
    return RegExp(r'^[a-zA-Z0-9ÁÉÍÓÚáéíóúÑñÜü \-_/.#]+$').hasMatch(limpio);
  }

  /// Deja solo los digitos de [texto] (util para telefono, CUIT, CBU y codigos).
  static String soloDigitos(String? texto) =>
      (texto ?? '').replaceAll(RegExp(r'\D'), '');
}
