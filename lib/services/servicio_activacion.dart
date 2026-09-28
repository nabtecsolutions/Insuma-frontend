import 'dart:math';
import '../data/repositorios/repositorio_codigos_activacion.dart';

/// Servicio de códigos de activación de negocio (HU-075).
///
/// El SuperAdmin emite un código y se lo entrega al dueño del negocio; sin un
/// código válido no se puede crear una cuenta. Un código es de **un solo uso** y
/// **vence a los 7 días** (configurable). El consumo real es atómico y ocurre en
/// el backend al registrarse; acá vive la validación previa (para dar un mensaje
/// claro antes de intentar el alta) y la emisión.
class ServicioActivacion {
  final RepositorioCodigosActivacion _repo;

  ServicioActivacion(this._repo);

  /// Vigencia por defecto de un código recién emitido.
  static const Duration vigenciaPorDefecto = Duration(days: 7);

  /// Alfabeto Crockford base32: 32 símbolos, SIN los glifos ambiguos I, L, O y U.
  /// Como no contiene 'O' ni 'I', al dictarlo no hay confusión con '0' y '1'.
  static const String _alfabeto = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Longitud del código (8 símbolos × 5 bits = 40 bits de entropía).
  static const int _longitud = 8;

  static final Random _aleatorio = Random.secure();

  /// Genera un código nuevo con formato legible `XXXX-XXXX`.
  /// Usa un generador criptográficamente seguro: el código habilita crear un negocio.
  String generarCodigo() {
    final simbolos = List.generate(
      _longitud,
      (_) => _alfabeto[_aleatorio.nextInt(_alfabeto.length)],
    );
    final crudo = simbolos.join();
    return '${crudo.substring(0, 4)}-${crudo.substring(4)}';
  }

  /// Normaliza un código tal como lo hace `normalizar_codigo_activacion` en SQL:
  /// quita todo lo que no sea alfanumérico, pasa a mayúsculas y resuelve los
  /// glifos ambiguos (O→0, I→1, L→1). Debe quedar SIEMPRE en espejo con el backend.
  String normalizar(String codigo) {
    final soloAlfanumerico = codigo
        .replaceAll(RegExp(r'[^0-9A-Za-z]'), '')
        .toUpperCase();
    return soloAlfanumerico
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
  }

  /// Formatea un código normalizado para mostrarlo (`XXXX-XXXX`).
  String formatear(String codigoNormalizado) {
    if (codigoNormalizado.length != _longitud) return codigoNormalizado;
    return '${codigoNormalizado.substring(0, 4)}-${codigoNormalizado.substring(4)}';
  }

  /// Valida [codigo] contra el backend ANTES de intentar el alta, para poder dar
  /// un mensaje claro. Devuelve `null` si el código sirve, o el mensaje de error.
  ///
  /// Si no hay conexión (o el backend no responde) devuelve el mensaje de
  /// conectividad: **sin validar el código no se permite crear el negocio**.
  Future<String?> validar(String codigo) async {
    final normalizado = normalizar(codigo);
    if (normalizado.isEmpty) {
      return 'Ingresá el código de acceso que te dio INSUMA.';
    }

    final EstadoCodigo estado;
    try {
      estado = await _repo.validar(normalizado);
    } catch (_) {
      return mensajeSinConexion;
    }
    return mensajeDe(estado);
  }

  /// Mensaje para cada veredicto. `null` significa que el código es utilizable.
  static String? mensajeDe(EstadoCodigo estado) => switch (estado) {
    EstadoCodigo.valido => null,
    EstadoCodigo.inexistente =>
      'El código no existe. Revisalo y volvé a intentar.',
    EstadoCodigo.consumido => 'Ese código ya fue usado para crear un negocio.',
    EstadoCodigo.revocado =>
      'Ese código fue dado de baja. Pedí uno nuevo a INSUMA.',
    EstadoCodigo.vencido => 'El código venció. Pedí uno nuevo a INSUMA.',
  };

  /// Sin conexión no se puede validar el código y, por lo tanto, no se puede crear
  /// un negocio: de lo contrario cualquiera podría darse de alta estando offline.
  static const String mensajeSinConexion =
      'Verificá tu conexión a internet y volvé a intentarlo: no pudimos validar tu código.';

  // --- Operaciones del SuperAdmin -----------------------------------------

  /// Emite un código nuevo y devuelve el texto formateado para entregárselo al
  /// cliente. [vigencia] por defecto son 7 días.
  Future<String> emitir({
    String? nota,
    Duration vigencia = vigenciaPorDefecto,
    DateTime? ahora,
  }) async {
    final codigo = generarCodigo();
    await _repo.emitir(
      codigo: normalizar(codigo),
      expiraEn: (ahora ?? DateTime.now()).add(vigencia),
      nota: nota,
    );
    return codigo;
  }

  Future<List<CodigoActivacion>> listar() => _repo.listar();

  Future<void> revocar(String id) => _repo.revocar(id);
}
