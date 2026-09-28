/// Unidades de medida de un insumo, y qué se puede cargar en cada una.
///
/// Existe porque la lista estaba escrita DOS veces a mano —en el alta de insumo
/// y en el modal de receta— sin ninguna fuente común. Dos copias del mismo dato
/// se desincronizan al primer cambio, que es exactamente lo que había pasado.
///
/// Módulo PURO: sin Flutter y sin base de datos. La UI arma sus dropdowns desde
/// acá; la regla de qué admite cada unidad vive acá y no en cada pantalla.
library;

/// Las unidades que la app ofrece al dar de alta un insumo.
///
/// El orden es el que ve el usuario en el desplegable, y sale de la frecuencia
/// de uso en una cocina: primero peso y volumen, después las de conteo.
const List<({String codigo, String nombre})> unidadesDisponibles = [
  (codigo: 'kg', nombre: 'Kilogramo (kg)'),
  (codigo: 'lt', nombre: 'Litro (lt)'),
  (codigo: 'u', nombre: 'Unidad (u)'),
  (codigo: 'paq', nombre: 'Paquete (paq)'),
  (codigo: 'atado', nombre: 'Atado'),
];

/// Unidades que se cuentan de a enteros: no existe media unidad, medio paquete
/// ni medio atado (#214).
///
/// ⚠ Es una regla de COMPRA, no de consumo. En una receta media lechuga es un
/// ingrediente perfectamente válido, así que las recetas NO usan esta regla.
const Set<String> unidadesEnteras = {'u', 'paq', 'atado'};

/// Decimales que admite una cantidad para [unidad].
const int decimalesCantidad = 3;

/// ¿La cantidad de un insumo medido en [unidad] tiene que ser entera?
///
/// Una unidad DESCONOCIDA devuelve `false`, o sea decimal. Es a propósito: en la
/// base hay unidades históricas que ya no se ofrecen (`g`, `ml`, `gr`, `l`,
/// `cc`) y pueden bajar otras de Supabase. Ante la duda se conserva el
/// comportamiento de siempre —permitir decimales— en vez de trabar un campo con
/// una regla que nadie declaró para esa unidad.
bool esUnidadEntera(String? unidad) =>
    unidad != null && unidadesEnteras.contains(unidad.trim().toLowerCase());

/// Decimales que debe admitir el campo de cantidad de un insumo en [unidad],
/// mirando TAMBIÉN el valor que ya tiene cargado.
///
/// El segundo argumento no es un detalle: `CampoNumerico` recorta el valor
/// inicial a los decimales que admite, así que devolver 0 para un ítem histórico
/// cargado con 2,5 u lo mostraría como 3. El PO decidió RESPETAR esos decimales
/// viejos en vez de redondearlos —redondear cambia una cantidad que alguien
/// cargó, y en un pedido eso es plata—, así que una unidad entera con un valor
/// fraccionario ya puesto sigue admitiendo decimales.
///
/// La excepción es sólo para lo que YA estaba: apenas la persona escribe un
/// valor nuevo entero, el campo vuelve a comportarse como entero.
int decimalesDeCantidad(String? unidad, [double? valorActual]) {
  if (!esUnidadEntera(unidad)) return decimalesCantidad;
  final tieneDecimales =
      valorActual != null && valorActual != valorActual.roundToDouble();
  return tieneDecimales ? decimalesCantidad : 0;
}
