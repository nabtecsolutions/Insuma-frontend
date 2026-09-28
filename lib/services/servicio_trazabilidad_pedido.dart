import '../data/repositorios/repositorio_cuenta_corriente.dart';
import '../data/repositorios/repositorio_recepciones.dart';
import '../data/repositorios/repositorio_usuarios.dart';
import '../database/database.dart';
import '../utils/trazabilidad_pedido.dart';

/// Arma los pasos de un pedido para mostrarlos en su detalle (#273).
///
/// Service propio y no un método más de `ServicioPedidos` por una razón de
/// dependencias: esto necesita recepciones, la cadena factura→pago y la tabla
/// de usuarios, tres cosas que aquel servicio no tiene ni tiene por qué tener.
/// Sumárselas ahí lo habría convertido en el servicio que sabe de todo.
///
/// La REGLA de qué pasos hay y cómo se leen vive en
/// `utils/trazabilidad_pedido.dart`, que es puro. Acá sólo se juntan los datos.
class ServicioTrazabilidadPedido {
  final RepositorioRecepciones _recepciones;
  final RepositorioCuentaCorriente _cuenta;
  final RepositorioUsuarios _usuarios;

  ServicioTrazabilidadPedido(this._recepciones, this._cuenta, this._usuarios);

  /// Los pasos de [pedido], en orden.
  ///
  /// Los nombres de usuario se resuelven en UNA tanda antes de armar los pasos,
  /// y no fila por fila dentro del módulo puro: son a lo sumo cuatro UUID y así
  /// el módulo no necesita ser asíncrono ni conocer un repositorio.
  Future<List<PasoTrazabilidad>> de(Pedido pedido) async {
    final recepciones = await _recepciones.listarPorPedido(pedido.id);
    final hechos = await _cuenta.hechosDeFacturacion(pedido.id);

    // Sólo los que hacen falta y no tienen nombre denormalizado en su fila.
    final aResolver = <String>{
      ?pedido.creadoPor,
      ?pedido.enviadoPor,
      for (final r in recepciones) ?r.recepcionadoPor,
      ?hechos.factura?.usuarioId,
      ?hechos.pago?.usuarioId,
    };

    final nombres = <String, String>{};
    for (final id in aResolver) {
      // Un usuario dado de baja, o que este dispositivo nunca bajó, es un caso
      // NORMAL: se deja sin nombre y el módulo muestra el paso igual. No se
      // aborta ni se inventa un "Usuario desconocido" que después alguien
      // confunde con un nombre real.
      final u = await _usuarios.obtener(id);
      if (u != null) nombres[id] = u.nombre;
    }

    return trazabilidadDe(
      pedido: pedido,
      recepciones: recepciones,
      factura: hechos.factura,
      pago: hechos.pago,
      resolverNombre: (uuid) => nombres[uuid],
    );
  }
}
