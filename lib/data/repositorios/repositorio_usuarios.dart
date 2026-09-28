import 'package:drift/drift.dart';
import '../../database/database.dart';
import '../mapeadores_supabase.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de Usuarios.
///
/// Abstrae el acceso Drift a la tabla `usuarios` (contrato + implementación Drift
/// registrada en [FabricaRepositorios]). Lo consume [ServicioAcceso] en el flujo
/// de login (HU-072).
///
/// HU-077: se eliminaron los métodos del PIN de elevación (`actualizarPinHash`,
/// `existeAdminConPin`). La columna `usuarios.pinHash` quedó HUÉRFANA: ninguna
/// capa la escribe ni la lee.
abstract class RepositorioUsuarios {
  Future<Usuario?> obtener(String id);

  /// Usuarios ACTIVOS con ese email (camino de login offline-first, HU-072).
  ///
  /// HU-135: devuelve LISTA porque el email puede repetirse entre negocios
  /// (dominio de HU-095: multi-membresía, dispositivo espejado). El singular
  /// con `.getSingleOrNull()` lanzaba `Too many elements` con dos filas activas
  /// y brickeaba el login antes de validar credenciales. Orden estable:
  /// más reciente primero.
  Future<List<Usuario>> listarActivosPorEmail(String email);

  /// Usuarios con ese email, sin importar si están activos (HU-135: lista por
  /// el mismo motivo). Orden estable: más reciente primero.
  Future<List<Usuario>> listarPorEmail(String email);

  /// Alta de un usuario nuevo que todavía NO existe en el backend → ENCOLA su INSERT.
  Future<Usuario> crear({
    required String id,
    required String negocioId,
    required String nombre,
    required String rol,
    String? email,
    String? passwordHash,
  });

  /// Espeja un usuario que YA existe en el backend (dispositivo nuevo). NO encola.
  Future<void> espejarLocal({
    required String id,
    required String negocioId,
    required String nombre,
    required String rol,
    String? email,
    String? passwordHash,
  });

  /// Adopta la identidad remota AUTORITATIVA de un usuario local cuyo tenant quedó
  /// desfasado (HU-029/HU-072). NO encola: la fila ya existe en el backend.
  ///
  /// HU-131: reconciliación ROBUSTA. Si ya existe otra fila local con el id
  /// destino, o una que ocupe el unique `(negocio_id, email)`, NO lanza: el
  /// remoto es autoritativo, así que los duplicados locales rancios se eliminan
  /// y la identidad destino se materializa por upsert preservando los campos que
  /// habilitan el login offline (email, hash, nombre, activo) de la fila actual.
  /// Antes era un UPDATE del id que lanzaba SqliteException ante la colisión y
  /// brickeaba el login.
  Future<void> reasignarIdentidad({
    required String idActual,
    required String nuevoId,
    required String negocioId,
    required String rol,
  });

  /// Reescribe SÓLO el hash local de la contraseña (HU-076).
  ///
  /// Update PARCIAL a propósito: `espejarLocal` es un upsert de la fila entera y
  /// forzaría `activo = true` (resucitando offline a un usuario dado de baja),
  /// pisaría nombre/rol y marcaría la fila como 'sincronizado', blanqueando la cola.
  ///
  /// NO encola: la columna `password_hash` no existe en la tabla remota y el mapper
  /// de push la excluye, así que encolar esto no sincronizaría nada — sólo empujaría
  /// datos locales rancios sobre el servidor.
  ///
  /// Pasar `null` INVALIDA la credencial local: el usuario deja de poder entrar
  /// offline y queda obligado a un login online (lo usa ServicioAcceso cuando detecta
  /// que la contraseña fue reseteada en la nube).
  Future<void> actualizarPasswordHash({
    required String id,
    required String? passwordHash,
  });

  /// Reconcilia el `activo` LOCAL con el valor AUTORITATIVO del backend (HU-071). NO
  /// encola: refleja el estado remoto, no es un cambio local a empujar. La baja de
  /// HU-076 Fase 3 la reutiliza: tras la Edge Function `dar-de-baja-usuario` (que ya
  /// escribió el `activo` server-side), espeja `activo=false` local para que la UI y el
  /// login offline reaccionen sin esperar el próximo pull.
  Future<void> reconciliarActivo({
    required String usuarioId,
    required bool activo,
  });
}

class RepositorioUsuariosDrift extends RepositorioSincronizable
    implements RepositorioUsuarios {
  RepositorioUsuariosDrift(super.db, super.sync);

  static const String _tabla = 'usuarios';

  @override
  Future<Usuario?> obtener(String id) =>
      (db.select(db.usuarios)..where((u) => u.id.equals(id))).getSingleOrNull();

  @override
  Future<List<Usuario>> listarActivosPorEmail(String email) =>
      (db.select(db.usuarios)
            ..where((u) => u.email.equals(email) & u.activo.equals(true))
            ..orderBy([(u) => OrderingTerm.desc(u.fechaCreacion)]))
          .get();

  @override
  Future<List<Usuario>> listarPorEmail(String email) =>
      (db.select(db.usuarios)
            ..where((u) => u.email.equals(email))
            ..orderBy([(u) => OrderingTerm.desc(u.fechaCreacion)]))
          .get();

  @override
  Future<Usuario> crear({
    required String id,
    required String negocioId,
    required String nombre,
    required String rol,
    String? email,
    String? passwordHash,
  }) async {
    await db
        .into(db.usuarios)
        .insert(
          UsuariosCompanion.insert(
            id: id,
            negocioId: negocioId,
            nombre: nombre,
            rol: Value(rol),
            email: Value(email),
            passwordHash: Value(passwordHash),
            activo: const Value(true),
            fechaCreacion: Value(DateTime.now()),
          ),
        );
    final creado = await (db.select(
      db.usuarios,
    )..where((u) => u.id.equals(id))).getSingle();
    await encolarInsert(_tabla, id, MapeadoresSupabase.usuario(creado));
    return creado;
  }

  @override
  Future<void> espejarLocal({
    required String id,
    required String negocioId,
    required String nombre,
    required String rol,
    String? email,
    String? passwordHash,
  }) async {
    await db
        .into(db.usuarios)
        .insertOnConflictUpdate(
          UsuariosCompanion.insert(
            id: id,
            negocioId: negocioId,
            nombre: nombre,
            rol: Value(rol),
            email: Value(email),
            passwordHash: Value(passwordHash),
            activo: const Value(true),
            fechaCreacion: Value(DateTime.now()),
            estadoSync: const Value('sincronizado'),
          ),
        );
  }

  @override
  Future<void> reasignarIdentidad({
    required String idActual,
    required String nuevoId,
    required String negocioId,
    required String rol,
  }) async {
    // HU-131: en transacción para que una falla a mitad de camino no deje al
    // usuario sin NINGUNA fila local (perdería el login offline).
    await db.transaction(() async {
      final actual = await (db.select(
        db.usuarios,
      )..where((u) => u.id.equals(idActual))).getSingleOrNull();
      if (actual == null) return; // nada que reasignar

      // 1. Liberar el id viejo (si difiere del destino).
      if (idActual != nuevoId) {
        await (db.delete(
          db.usuarios,
        )..where((u) => u.id.equals(idActual))).go();
      }
      // 2. Liberar el unique (negocio_id, email): cualquier OTRA fila del negocio
      //    destino con este email es un duplicado local rancio de la misma persona
      //    (el remoto es autoritativo) y bloquearía el upsert.
      final email = actual.email;
      if (email != null) {
        await (db.delete(db.usuarios)..where(
              (u) =>
                  u.negocioId.equals(negocioId) &
                  u.email.equals(email) &
                  u.id.equals(nuevoId).not(),
            ))
            .go();
      }
      // 3. Materializar la identidad destino preservando lo que habilita el login
      //    offline de la fila que acaba de validar (email/hash/nombre/activo/fecha).
      await db
          .into(db.usuarios)
          .insertOnConflictUpdate(
            UsuariosCompanion.insert(
              id: nuevoId,
              negocioId: negocioId,
              nombre: actual.nombre,
              rol: Value(rol),
              email: Value(actual.email),
              passwordHash: Value(actual.passwordHash),
              activo: Value(actual.activo),
              fechaCreacion: Value(actual.fechaCreacion),
              estadoSync: const Value('sincronizado'),
            ),
          );
    });
  }

  @override
  Future<void> actualizarPasswordHash({
    required String id,
    required String? passwordHash,
  }) async {
    await (db.update(db.usuarios)..where((u) => u.id.equals(id))).write(
      // Value(null) escribe NULL (invalida la credencial); Value(hash) la fija.
      UsuariosCompanion(passwordHash: Value(passwordHash)),
    );
  }

  @override
  Future<void> reconciliarActivo({
    required String usuarioId,
    required bool activo,
  }) async {
    await (db.update(db.usuarios)..where((u) => u.id.equals(usuarioId))).write(
      UsuariosCompanion(
        activo: Value(activo),
        estadoSync: const Value('sincronizado'),
      ),
    );
  }
}
