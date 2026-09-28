/// El IVA: alícuotas, conversiones y totales de una factura de compra (#225).
///
/// Módulo PURO —sin Flutter y sin base de datos— igual que los otros de esta
/// carpeta. Toda la aritmética que la pantalla de procesar recepción necesita
/// vive acá, testeada sola, para que la pantalla sólo dibuje.
///
/// ── LA ESCALA ES FRACCIÓN, no porcentaje ────────────────────────────────────
/// 21% se escribe `0.21`. Es la escala que el código ya usa en todos sus call
/// sites y la que documenta el propio esquema local: `HistorialPrecios`
/// declara `ivaPorcentaje` como `real().withDefault(const Constant(0.21))`.
///
/// ⚠ **Postgres estaba declarado al revés.** El baseline
/// (`20260621034530_baseline_remote_schema.sql:408`) decía
/// `"iva_porcentaje" real DEFAULT 21.0`, o sea PORCENTAJE. No explotaba por una
/// razón frágil: el valor viaja SIEMPRE explícito desde el cliente, así que el
/// default del servidor nunca se usaba. Una fila insertada del lado servidor sin
/// ese campo habría quedado con 21.0 en una columna que la app lee como 2100%.
///
/// Lo corrige la migración de #229 (`20260827120000_hu229_factura_items.sql`),
/// que es cuando la columna empieza a leerse de verdad, y de paso deja la
/// alícuota del renglón nuevo declarada en fracción de las dos puntas.
library;

import 'dinero.dart';

/// Una alícuota que la app ofrece, con su etiqueta para el botón.
typedef Alicuota = ({String etiqueta, double fraccion});

/// Las cuatro alícuotas, en el orden en que se muestran.
///
/// "Exento" es una alícuota de verdad y no la ausencia de una: un insumo exento
/// factura con IVA cero, y eso es distinto de "todavía no elegí la alícuota".
/// Modelarlo como 0 y no como `null` evita que la pantalla tenga que distinguir
/// dos nadas.
const List<Alicuota> alicuotas = [
  (etiqueta: 'Exento', fraccion: 0.0),
  (etiqueta: '10.5%', fraccion: 0.105),
  (etiqueta: '21%', fraccion: 0.21),
  (etiqueta: '27%', fraccion: 0.27),
];

/// La que viene marcada al abrir el panel de un ítem.
const double alicuotaPorDefecto = 0.21;

/// ¿Es una de las alícuotas que la app admite?
///
/// Sirve para no confiar en un número que bajó de la base: una fila vieja con
/// `21.0` —la escala equivocada— no pasa este control.
bool esAlicuotaValida(double fraccion) =>
    alicuotas.any((a) => a.fraccion == fraccion);

/// El IVA de un importe neto.
double ivaDe(double neto, double alicuota) => Dinero.redondear(neto * alicuota);

/// El importe CON IVA a partir del neto.
///
/// Se calcula como `neto + ivaDe(...)` y NO como `neto * (1 + alicuota)`: así el
/// bruto es exactamente la suma de las dos cifras que la pantalla muestra. Con
/// la otra forma, neto e IVA podían mostrarse redondeados y no sumar el total.
double brutoDe(double neto, double alicuota) =>
    Dinero.redondear(neto + ivaDe(neto, alicuota));

/// El neto a partir de un importe que YA tiene IVA.
///
/// Es la vuelta de [brutoDe], para cuando la persona tipea lo que dice la
/// factura —que viene con IVA— en vez del neto.
double netoDesdeBruto(double bruto, double alicuota) =>
    Dinero.redondear(bruto / (1 + alicuota));

/// El precio de UNA unidad a partir del total de la línea.
///
/// Es la mitad de la conversión que el PO pidió poder elegir: cargar el total
/// del ítem y que se divida, o cargar el unitario y que se multiplique.
///
/// Con cantidad cero devuelve cero en vez de infinito: una línea sin cantidad no
/// tiene precio unitario, y propagar un `Infinity` rompería todos los totales de
/// la pantalla sin decir dónde.
double unitarioDesdeTotal(double total, double cantidad) =>
    cantidad <= 0 ? 0.0 : Dinero.redondear(total / cantidad);

/// El total de la línea a partir del precio de una unidad. La otra mitad.
double totalDesdeUnitario(double unitario, double cantidad) =>
    cantidad <= 0 ? 0.0 : Dinero.redondear(unitario * cantidad);

/// Una línea de la factura: lo que se cargó para UN insumo recibido.
class LineaCosto {
  /// Qué insumo es. Sin esto la línea no puede costear: es el argumento con el
  /// que la pantalla llama a `ServicioPrecios.registrar`, y la columna por la
  /// que se persiste el renglón.
  ///
  /// Es obligatorio y no nullable aunque la aritmética no lo use, porque toda
  /// línea real viene de un ítem recibido y siempre lo tiene. Dejarlo opcional
  /// sólo movería el problema al lugar donde más duele: un `!` en el momento de
  /// guardar.
  final String insumoId;

  /// Precio NETO de una unidad, sin IVA.
  final double netoUnitario;

  /// Cuánto entró. Sale de la recepción y no se edita acá.
  final double cantidad;

  /// Alícuota en FRACCIÓN (0.21 = 21%).
  final double alicuota;

  const LineaCosto({
    required this.insumoId,
    required this.netoUnitario,
    required this.cantidad,
    this.alicuota = alicuotaPorDefecto,
  });

  /// Neto de toda la línea.
  double get subtotalNeto => totalDesdeUnitario(netoUnitario, cantidad);

  /// Precio de una unidad CON IVA.
  double get brutoUnitario => brutoDe(netoUnitario, alicuota);

  /// El IVA de la línea entera.
  double get iva => ivaDe(subtotalNeto, alicuota);

  /// La línea entera con IVA.
  double get subtotalBruto => Dinero.redondear(subtotalNeto + iva);
}

/// Los tres números del pie de la factura.
class ResumenIva {
  final double subtotalNeto;
  final double iva;
  final double total;

  const ResumenIva({
    required this.subtotalNeto,
    required this.iva,
    required this.total,
  });

  /// Suma las líneas.
  ///
  /// El IVA se calcula y se redondea POR LÍNEA y después se suma, que es como lo
  /// hace una factura de verdad. Calcularlo sobre el neto total daría un centavo
  /// de diferencia cuando hay varias alícuotas mezcladas, y un total que no
  /// cierra contra el papel del proveedor hace desconfiar de todo el número.
  ///
  /// Sin líneas devuelve todo en cero, que es lo correcto: una factura sin
  /// renglones no debe nada.
  factory ResumenIva.de(List<LineaCosto> lineas) {
    var neto = 0.0;
    var impuesto = 0.0;
    for (final l in lineas) {
      neto += l.subtotalNeto;
      impuesto += l.iva;
    }
    neto = Dinero.redondear(neto);
    impuesto = Dinero.redondear(impuesto);
    return ResumenIva(
      subtotalNeto: neto,
      iva: impuesto,
      total: Dinero.redondear(neto + impuesto),
    );
  }
}
