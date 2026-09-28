import 'package:flutter/services.dart';

import 'validador_datos.dart';

/// Formateadores de ENTRADA (HU-137): impiden TIPEAR lo que no corresponde.
///
/// Es la mitad preventiva de la validacion. La otra mitad —decir si lo escrito
/// es valido— vive en [ValidadorDatos]; esta capa evita que el caracter invalido
/// llegue siquiera al campo.
///
/// Por que hace falta: `keyboardType` es solo una SUGERENCIA de teclado. En Flutter
/// Web y escritorio (donde el equipo prueba) no impide nada, y ni en Android frena
/// un pegado desde el portapapeles. Sin estos formateadores, "abc" entraba en un
/// campo de dinero y se guardaba como 0.
class FormatosEntrada {
  const FormatosEntrada._();

  /// Decimales de un importe (centavos) y de una cantidad (gramos, mililitros).
  static const int decimalesDinero = 2;
  static const int decimalesCantidad = 3;

  /// Numero decimal con coma O punto (HU-137: en Argentina se escribe "12,5").
  /// Acepta el texto PARCIAL mientras se tipea ("12", "12," , "12,5").
  static List<TextInputFormatter> decimal({int decimales = decimalesDinero}) =>
      [_FormateadorDecimal(decimales)];

  /// Importe de dinero: 2 decimales.
  static List<TextInputFormatter> dinero() =>
      decimal(decimales: decimalesDinero);

  /// Cantidad de mercaderia o de receta: 3 decimales (0,125 kg).
  static List<TextInputFormatter> cantidad() =>
      decimal(decimales: decimalesCantidad);

  /// Entero sin signo (porciones, minutos, dias, cada X dias).
  static List<TextInputFormatter> entero({int maxDigitos = 9}) => [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(maxDigitos),
  ];

  /// Solo digitos, con largo exacto conocido: CUIT (11), CBU (22), codigo de
  /// activacion o de recuperacion (8).
  static List<TextInputFormatter> soloDigitos({required int largo}) => [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(largo),
  ];

  /// Telefono: digitos mas los separadores habituales que [ValidadorDatos.validarTelefono]
  /// ya tolera (+, espacio, guion, parentesis).
  static List<TextInputFormatter> telefono({int maxLongitud = 25}) => [
    FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-() ]')),
    LengthLimitingTextInputFormatter(maxLongitud),
  ];

  /// Identificador alfanumerico de negocio (numero de factura, remito, referencia).
  static List<TextInputFormatter> alfanumerico({int maxLongitud = 60}) => [
    FilteringTextInputFormatter.allow(
      RegExp(r'[a-zA-Z0-9ÁÉÍÓÚáéíóúÑñÜü \-_/.#]'),
    ),
    LengthLimitingTextInputFormatter(maxLongitud),
  ];

  /// Email: cualquier caracter menos espacios (el formato se valida al guardar).
  static List<TextInputFormatter> email({int maxLongitud = 120}) => [
    FilteringTextInputFormatter.deny(RegExp(r'\s')),
    LengthLimitingTextInputFormatter(maxLongitud),
  ];

  /// Texto libre (nombres, notas): solo se acota el largo. La normalizacion
  /// (trim y colapso de espacios) se hace al guardar con [SanitizadorTexto],
  /// para no pelearle al usuario mientras escribe.
  static List<TextInputFormatter> texto({int maxLongitud = 120}) => [
    LengthLimitingTextInputFormatter(maxLongitud),
  ];
}

/// Deja escribir un decimal con coma o punto, con un maximo de [decimales].
///
/// Valida el texto RESULTANTE (no el caracter suelto) para poder aceptar estados
/// intermedios legitimos: "" , "12", "12," y "12,5" son todos tipeos validos en
/// camino a un numero. Si el resultado no encaja, se rechaza la edicion
/// devolviendo el valor anterior — el caracter nunca aparece en pantalla.
class _FormateadorDecimal extends TextInputFormatter {
  _FormateadorDecimal(this.decimales)
    : _patron = RegExp(
        decimales > 0
            ? r'^\d*([.,]\d{0,'
                  '$decimales'
                  r'})?$'
            : r'^\d*$',
      );

  final int decimales;
  final RegExp _patron;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue anterior,
    TextEditingValue nuevo,
  ) {
    if (nuevo.text.isEmpty) return nuevo;
    if (_patron.hasMatch(nuevo.text)) return nuevo;

    // El usuario NO tipea separadores de miles, pero sí PEGA importes que los
    // traen ("$ 1.500,25" copiado de un mensaje). Rechazar el pegado entero
    // dejaría el campo vacío sin explicación: si se puede interpretar, se
    // normaliza. Se distingue el pegado del tipeo por el salto de longitud, para
    // no reescribirle el campo a alguien que está escribiendo carácter a carácter.
    final esPegado = nuevo.text.length - anterior.text.length > 1;
    if (esPegado) {
      final valor = ValidadorDatos.parsearNumero(nuevo.text);
      if (valor != null && valor >= 0) {
        final texto = _canonico(valor);
        return TextEditingValue(
          text: texto,
          selection: TextSelection.collapsed(offset: texto.length),
        );
      }
    }
    return anterior;
  }

  /// Representación sin separador de miles y sin ceros decimales colgando.
  String _canonico(double valor) {
    var texto = valor.toStringAsFixed(decimales);
    if (texto.contains('.')) {
      texto = texto
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    return texto;
  }
}
