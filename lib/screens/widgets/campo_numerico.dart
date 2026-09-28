import 'package:flutter/material.dart';

import '../../utils/formatos_entrada.dart';
import '../../utils/validador_datos.dart';

/// Campo de texto para valores NUMERICOS (HU-137).
///
/// Empaqueta en un solo lugar las tres piezas que antes faltaban o estaban sueltas
/// en cada pantalla:
///  1. el teclado numerico,
///  2. los [FormatosEntrada] que impiden tipear lo que no es un numero,
///  3. el parseo tolerante a coma y punto de [ValidadorDatos.parsearNumero].
///
/// La diferencia de fondo con el codigo anterior: [alCambiar] entrega `null`
/// cuando lo escrito NO es un numero valido. Antes cada pantalla hacia
/// `double.tryParse(v) ?? 0.0` y un tipeo invalido se guardaba como CERO en
/// silencio — en campos de dinero eso es un importe perdido.
///
/// Se usa igual dentro de un [Form] (valida solo, con [validator]) que fuera de
/// uno (la pantalla decide mirando si [alCambiar] recibio `null`).
class CampoNumerico extends StatelessWidget {
  const CampoNumerico({
    super.key,
    required this.etiqueta,
    this.controlador,
    this.valorInicial,
    this.alCambiar,
    this.alGuardar,
    this.decimales = FormatosEntrada.decimalesDinero,
    this.obligatorio = true,
    this.permitirCero = false,
    this.sufijo,
    this.prefijo,
    this.iconoSufijo,
    this.denso = false,
    this.habilitado = true,
    this.autofocus = false,
    this.estilo,
    this.ayuda,
    this.paso,
  }) : assert(
         controlador == null || valorInicial == null,
         'Usá controlador O valorInicial, no ambos (TextFormField no lo permite)',
       );

  /// Texto de la etiqueta, SIN el asterisco: lo agrega [obligatorio].
  final String etiqueta;

  /// Controlador propio, cuando la pantalla necesita reescribir el campo
  /// (por ejemplo el reset de cantidad al marcar un item como rechazado).
  final TextEditingController? controlador;

  /// Valor con el que arranca el campo cuando no se usa [controlador].
  final double? valorInicial;

  /// Recibe el valor interpretado, o `null` si lo escrito no es un numero valido
  /// (campo vacio incluido). Nunca convierte basura en 0.
  final ValueChanged<double?>? alCambiar;

  /// Equivalente a `onSaved` para formularios que guardan con `_formKey.save()`.
  final ValueChanged<double?>? alGuardar;

  /// Decimales admitidos: 2 para dinero, 3 para cantidades. Ver [FormatosEntrada].
  final int decimales;

  /// Si es obligatorio, un campo vacio es invalido y la etiqueta lleva ` *`.
  final bool obligatorio;

  /// Permite el cero (porcentaje de desperdicio, cantidad recibida en un rechazo).
  final bool permitirCero;

  final String? sufijo;
  final String? prefijo;

  /// Acción al final del campo (por ejemplo el conversor de unidades de recetas).
  final Widget? iconoSufijo;
  final bool denso;
  final bool habilitado;
  final bool autofocus;
  final TextStyle? estilo;
  final String? ayuda;

  /// Si viene, el campo suma dos botones —menos a la izquierda, más a la
  /// derecha— que ajustan el valor de a [paso] (#214).
  ///
  /// Es OPT-IN a propósito. Este widget lo usan también los campos de dinero,
  /// totales y porcentajes, donde el PO no pidió botones y donde sumar de a uno
  /// no significa nada. Sólo lo declaran los cuatro campos de CANTIDAD.
  ///
  /// Con [paso] el campo pasa a ser CONTROLADO —los botones tienen que poder
  /// reescribir el texto— así que [valorInicial] se usa una sola vez, para
  /// sembrar el controlador interno.
  final double? paso;

  /// Formatea un valor para MOSTRARLO en el campo: sin el `.0` de los enteros
  /// (`12.0` -> `"12"`) y vacio cuando no hay dato.
  static String textoDe(double? valor) {
    if (valor == null) return '';
    if (valor == valor.roundToDouble() && valor.abs() < 1e15) {
      return valor.toInt().toString();
    }
    return valor.toString();
  }

  /// El valor de arranque se muestra con los decimales que el campo ADMITE.
  ///
  /// Sin esto, un valor calculado (por ejemplo 100 g / 120 = 0,8333333333333334
  /// que devuelve el conversor de unidades de recetas) se pintaría con 16
  /// decimales y el campo quedaría trabado: el formateador rechazaría cualquier
  /// tecla nueva por exceder el máximo, y solo se podría borrar.
  double? _paraMostrar(double? valor) {
    if (valor == null) return null;
    return double.parse(valor.toStringAsFixed(decimales));
  }

  String? _validar(String? texto) {
    final vacio = (texto ?? '').trim().isEmpty;
    if (vacio) return obligatorio ? 'Ingresá $etiqueta' : null;
    if (!ValidadorDatos.esNumeroValido(texto)) {
      return 'Solo números (ej. 12,50)';
    }
    if (!ValidadorDatos.validarNumeroPositivo(
      texto,
      permitirCero: permitirCero,
    )) {
      return permitirCero ? 'No puede ser negativo' : 'Debe ser mayor a 0';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Sin `paso` el campo es EXACTAMENTE el de siempre. Los más de veinte call
    // sites que no piden botones no cambian de comportamiento ni de árbol.
    if (paso == null) {
      return campoDeTexto(
        controlador: controlador,
        textoInicial: controlador == null
            ? textoDe(_paraMostrar(valorInicial))
            : null,
      );
    }
    return _CampoConPaso(campo: this);
  }

  /// El `TextFormField` en sí, sin los botones.
  ///
  /// Se expone para que [_CampoConPaso] lo reuse con SU controlador en vez de
  /// duplicar la configuración —formateadores, validador, teclado— que es
  /// justamente lo que este widget vino a centralizar.
  Widget campoDeTexto({
    TextEditingController? controlador,
    String? textoInicial,
  }) {
    return TextFormField(
      controller: controlador,
      initialValue: textoInicial,
      enabled: habilitado,
      autofocus: autofocus,
      keyboardType: TextInputType.numberWithOptions(decimal: decimales > 0),
      inputFormatters: FormatosEntrada.decimal(decimales: decimales),
      style: estilo ?? const TextStyle(color: Colors.black87),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(
        labelText: obligatorio ? '$etiqueta *' : etiqueta,
        suffixText: sufijo,
        prefixText: prefijo,
        suffixIcon: iconoSufijo,
        helperText: ayuda,
        isDense: denso,
      ),
      validator: _validar,
      onChanged: alCambiar == null
          ? null
          : (v) => alCambiar!(ValidadorDatos.parsearNumero(v)),
      onSaved: alGuardar == null
          ? null
          : (v) => alGuardar!(ValidadorDatos.parsearNumero(v)),
    );
  }
}

/// El campo con los botones de más y menos (#214).
///
/// Es `Stateful` porque los botones necesitan reescribir el texto, y para eso
/// hace falta un `TextEditingController` que sobreviva a los rebuilds.
///
/// El paso se SUMA al valor actual, no lo redondea a un múltiplo: un ítem
/// histórico cargado con 2,5 u pasa a 3,5 al tocar más. Redondear cambiaría una
/// cantidad que alguien cargó, y en un pedido eso es plata (la misma razón por
/// la que esos decimales viejos se respetan en vez de ajustarse).
class _CampoConPaso extends StatefulWidget {
  const _CampoConPaso({required this.campo});

  final CampoNumerico campo;

  @override
  State<_CampoConPaso> createState() => _CampoConPasoState();
}

class _CampoConPasoState extends State<_CampoConPaso> {
  late final TextEditingController _propio;

  /// El controlador que manda: el que trajo el llamador, o el interno.
  TextEditingController get _ctrl => widget.campo.controlador ?? _propio;

  @override
  void initState() {
    super.initState();
    _propio = TextEditingController(
      text: CampoNumerico.textoDe(widget.campo.valorInicial),
    );
  }

  @override
  void dispose() {
    _propio.dispose();
    super.dispose();
  }

  void _ajustar(double delta) {
    final actual = ValidadorDatos.parsearNumero(_ctrl.text) ?? 0.0;
    // Nunca por debajo de cero: el campo ya rechaza negativos, y dejar que el
    // botón los produjera sería fabricar un valor que el validador marca en rojo.
    final nuevo = (actual + delta).clamp(0.0, double.infinity);
    // Se normaliza a los decimales del campo: sin esto, 0.1 + 0.2 escribe
    // 0.30000000000000004 y el formateador traba el campo.
    final texto = CampoNumerico.textoDe(
      double.parse(nuevo.toStringAsFixed(widget.campo.decimales)),
    );
    _ctrl.value = TextEditingValue(
      text: texto,
      selection: TextSelection.collapsed(offset: texto.length),
    );
    widget.campo.alCambiar?.call(ValidadorDatos.parsearNumero(texto));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final paso = widget.campo.paso!;
    final habilitado = widget.campo.habilitado;
    final actual = ValidadorDatos.parsearNumero(_ctrl.text) ?? 0.0;
    return Row(
      children: [
        _BotonPaso(
          icono: Icons.remove,
          etiqueta: 'Restar $paso',
          // En cero no hay nada que restar: el botón lo dice apagándose, en vez
          // de no hacer nada al tocarlo.
          alTocar: habilitado && actual > 0 ? () => _ajustar(-paso) : null,
        ),
        Expanded(child: widget.campo.campoDeTexto(controlador: _ctrl)),
        _BotonPaso(
          icono: Icons.add,
          etiqueta: 'Sumar $paso',
          alTocar: habilitado ? () => _ajustar(paso) : null,
        ),
      ],
    );
  }
}

/// Botón de paso: chico y sin relleno, porque va dentro de filas angostas donde
/// cada píxel cuenta (esas filas ya desbordaron tres veces en este proyecto).
class _BotonPaso extends StatelessWidget {
  const _BotonPaso({
    required this.icono,
    required this.etiqueta,
    required this.alTocar,
  });

  final IconData icono;
  final String etiqueta;
  final VoidCallback? alTocar;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: alTocar,
      tooltip: etiqueta,
      icon: Icon(icono, size: 18),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
