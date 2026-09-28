import '../database/database.dart';
import '../services/servicio_sincronizacion_supabase.dart';
import 'config_persistencia.dart';
import 'repositorios/repositorio_configuracion.dart';
import 'repositorios/repositorio_negocios.dart';
import 'repositorios/repositorio_pedidos.dart';
import 'repositorios/repositorio_usuarios.dart';
import 'repositorios/repositorio_recepciones.dart';
import 'repositorios/repositorio_motivos_recepcion.dart';
import 'repositorios/repositorio_categorias.dart';
import 'repositorios/repositorio_proveedor_categorias.dart';
import 'repositorios/repositorio_adjuntos.dart';
import 'repositorios/repositorio_factura_items.dart';
import 'repositorios/repositorio_facturas.dart';
import 'repositorios/repositorio_cuenta_corriente.dart';
import 'repositorios/repositorio_auditoria.dart';
import 'repositorios/repositorio_pedidos_recurrentes.dart';

/// Fábrica que ensambla el conjunto de repositorios ACTIVO según la estrategia
/// de persistencia elegida en `.env` (APP_PERSISTENCIA).
///
/// El store local (Drift) es siempre la fuente offline-first. Cuando la
/// sincronización está activa (`hibrido`/`supabase`), los repositorios encolan
/// sus mutaciones hacia el "Model" remoto de Supabase mediante [sync]. En modo
/// `local`, [sync] se omite y no se sincroniza nada.
///
/// Esta indirección permite sustituir, en el futuro, las implementaciones Drift
/// por implementaciones nativas de Supabase sin tocar servicios ni controladores.
class FabricaRepositorios {
  final BaseDatosApp db;
  final ServicioSincronizacionSupabase? sync;

  FabricaRepositorios._(this.db, this.sync);

  factory FabricaRepositorios.crear({
    required BaseDatosApp db,
    ServicioSincronizacionSupabase? sync,
  }) {
    final usarSync = ConfigPersistencia.sincronizacionActiva;
    return FabricaRepositorios._(db, usarSync ? sync : null);
  }

  late final RepositorioConfiguracion configuracion =
      RepositorioConfiguracionDrift(db, sync);
  late final RepositorioPedidos pedidos = RepositorioPedidosDrift(db, sync);
  late final RepositorioUsuarios usuarios = RepositorioUsuariosDrift(db, sync);
  late final RepositorioNegocios negocios = RepositorioNegociosDrift(db, sync);
  late final RepositorioRecepciones recepciones = RepositorioRecepcionesDrift(
    db,
    sync,
  );
  late final RepositorioMotivosRecepcion motivosRecepcion =
      RepositorioMotivosRecepcionDrift(db, sync);
  // #262: catálogo de categorías de insumo (entidad de primera clase).
  late final RepositorioCategorias categorias = RepositorioCategoriasDrift(
    db,
    sync,
  );
  // #262: qué categorías suministra cada proveedor (reemplaza insumoProveedores).
  late final RepositorioProveedorCategorias proveedorCategorias =
      RepositorioProveedorCategoriasDrift(db, sync);
  late final RepositorioAdjuntos adjuntos = RepositorioAdjuntosDrift(db, sync);
  late final RepositorioFacturas facturas = RepositorioFacturasDrift(db, sync);
  late final RepositorioFacturaItems facturaItems =
      RepositorioFacturaItemsDrift(db, sync);
  late final RepositorioCuentaCorriente cuentaCorriente =
      RepositorioCuentaCorrienteDrift(db, sync);
  late final RepositorioAuditoria auditoria = RepositorioAuditoriaDrift(
    db,
    sync,
  );

  /// HU-013: las agendas de pedidos recurrentes.
  late final RepositorioPedidosRecurrentes pedidosRecurrentes =
      RepositorioPedidosRecurrentesDrift(db, sync);
}
