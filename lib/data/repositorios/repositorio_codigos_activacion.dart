import 'package:supabase_flutter/supabase_flutter.dart';

/// Veredicto de un código de activación (HU-075). Espeja los valores que devuelve
/// la función `validar_codigo_activacion` de Supabase.
///
/// `vencido` es un estado DERIVADO en el backend (`expira_en <= now()`), no una
/// columna: por eso nunca aparece almacenado.
enum EstadoCodigo { valido, inexistente, consumido, revocado, vencido }

/// Un código de activación tal como lo ve el SuperAdmin en su panel.
class CodigoActivacion {
  final String id;
  final String codigo;
  final String estado; // emitido | consumido | revocado
  final String? nota;
  final DateTime expiraEn;
  final DateTime? consumidoEn;
  final String? negocioId;

  const CodigoActivacion({
    required this.id,
    required this.codigo,
    required this.estado,
    required this.nota,
    required this.expiraEn,
    required this.consumidoEn,
    required this.negocioId,
  });

  /// Vencimiento derivado: un código `emitido` cuya fecha ya pasó es inservible.
  bool get vencido => estado == 'emitido' && !expiraEn.isAfter(DateTime.now());

  /// Sigue siendo utilizable por un negocio nuevo.
  bool get disponible => estado == 'emitido' && !vencido;

  factory CodigoActivacion.desdeMapa(Map<String, dynamic> m) =>
      CodigoActivacion(
        id: m['id'] as String,
        codigo: m['codigo'] as String,
        estado: m['estado'] as String,
        nota: m['nota'] as String?,
        expiraEn: DateTime.parse(m['expira_en'] as String).toLocal(),
        consumidoEn: m['consumido_en'] == null
            ? null
            : DateTime.parse(m['consumido_en'] as String).toLocal(),
        negocioId: m['negocio_id'] as String?,
      );
}

/// Contrato del repositorio de códigos de activación (HU-075).
///
/// [validar] es la ÚNICA operación disponible sin autenticación: la resuelve una
/// función `SECURITY DEFINER` en Supabase que devuelve un veredicto sin exponer la
/// tabla. Las demás son exclusivas del SuperAdmin (RLS `is_superadmin()`).
///
/// Todas lanzan si no hay conexión: el servicio traduce esa falla a un mensaje.
abstract class RepositorioCodigosActivacion {
  /// Veredicto de [codigo] (el backend lo normaliza). No consume nada.
  Future<EstadoCodigo> validar(String codigo);

  /// Emite un código nuevo. [codigo] debe venir ya normalizado.
  Future<void> emitir({
    required String codigo,
    required DateTime expiraEn,
    String? nota,
  });

  /// Códigos emitidos, más recientes primero.
  Future<List<CodigoActivacion>> listar();

  /// Revoca un código todavía no consumido.
  Future<void> revocar(String id);
}

class RepositorioCodigosActivacionSupabase
    implements RepositorioCodigosActivacion {
  final SupabaseClient _cliente;

  RepositorioCodigosActivacionSupabase(this._cliente);

  static const String _tabla = 'codigos_activacion';

  @override
  Future<EstadoCodigo> validar(String codigo) async {
    final veredicto = await _cliente.rpc<dynamic>(
      'validar_codigo_activacion',
      params: {'p_codigo': codigo},
    );
    return switch (veredicto as String?) {
      'valido' => EstadoCodigo.valido,
      'consumido' => EstadoCodigo.consumido,
      'revocado' => EstadoCodigo.revocado,
      'vencido' => EstadoCodigo.vencido,
      _ => EstadoCodigo.inexistente,
    };
  }

  @override
  Future<void> emitir({
    required String codigo,
    required DateTime expiraEn,
    String? nota,
  }) async {
    final notaLimpia = (nota ?? '').trim();
    await _cliente.from(_tabla).insert(<String, dynamic>{
      'codigo': codigo,
      'expira_en': expiraEn.toUtc().toIso8601String(),
      'nota': notaLimpia.isEmpty ? null : notaLimpia,
      'emitido_por': _cliente.auth.currentUser?.id,
    });
  }

  @override
  Future<List<CodigoActivacion>> listar() async {
    final datos = await _cliente
        .from(_tabla)
        .select('id, codigo, estado, nota, expira_en, consumido_en, negocio_id')
        .order('created_at', ascending: false);
    return (datos as List)
        .cast<Map<String, dynamic>>()
        .map(CodigoActivacion.desdeMapa)
        .toList();
  }

  @override
  Future<void> revocar(String id) async {
    await _cliente
        .from(_tabla)
        .update(<String, dynamic>{'estado': 'revocado'})
        .eq('id', id);
  }
}
