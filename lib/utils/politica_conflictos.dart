/// Política de resolución de conflictos de sincronización (HU-028).
///
/// Lógica PURA (sin BBDD ni red) para poder testear las reglas en aislamiento.
/// El pull la consulta antes de aplicar cada fila remota.
///
/// Dos familias de tablas, dos reglas:
///  • **Maestros** (mutables, con `version`): last-write-wins por `version`. Es
///    un contador exacto: se prefiere a los timestamps porque no depende del
///    reloj del dispositivo (uno mal configurado ganaría todos los desempates).
///  • **Append-only** (finanzas y evidencia): NUNCA se sobrescriben. El pull solo
///    inserta lo que falta; una divergencia de contenido es un conflicto para
///    revisión, no una excusa para pisar un asiento contable o un remito.
library;

/// Familia de una tabla a efectos de conflictos.
enum FamiliaTabla {
  /// Mutable: se resuelve por LWW sobre `version`.
  maestro,

  /// Inmutable tras su creación: insert-if-absent.
  appendOnly,

  /// Financiera mutable acotada: solo se acepta del servidor la transición de
  /// ESTADO (derivada de imputaciones); un cambio de importes es conflicto.
  /// Decisión del PO (2026-07-29): "es dinero".
  financieraDeEstado,
}

class PoliticaConflictos {
  const PoliticaConflictos._();

  static const Map<String, FamiliaTabla> _familias = {
    // Maestros mutables.
    'negocios': FamiliaTabla.maestro,
    'usuarios': FamiliaTabla.maestro,
    'proveedores': FamiliaTabla.maestro,
    'insumos': FamiliaTabla.maestro,
    'insumos_operativo': FamiliaTabla.maestro,
    'recetas': FamiliaTabla.maestro,
    'recetas_operativo': FamiliaTabla.maestro,
    'receta_ingredientes': FamiliaTabla.maestro,
    // HU-138: el catálogo de suministro es editable (precio de lista, alta y
    // baja lógica del vínculo), así que se resuelve por contador de versión
    // como cualquier maestro. NO es append-only: no es evidencia de nada.
    'insumo_proveedores': FamiliaTabla.maestro,
    // HU-013: la agenda de un pedido recurrente es configuración editable
    // (ítems, periodicidad, pausar, dar de baja), así que se resuelve por
    // contador de versión como cualquier maestro. Se declara EXPLÍCITO y no se
    // deja caer en el default de `familiaDe`: acá el default acierta por
    // casualidad, y una tabla nueva que cayera en la familia equivocada sin que
    // nadie lo decidiera es exactamente el tipo de error que este mapa existe
    // para evitar.
    'pedidos_recurrentes': FamiliaTabla.maestro,
    'pedidos': FamiliaTabla.maestro,
    'motivos_recepcion': FamiliaTabla.maestro,
    // #262: el catálogo de categorías y la asignación proveedor↔categoría son
    // configuración editable (crear/renombrar/baja lógica), con `version` como
    // token LWW/optimista. NO son evidencia → maestro, declaradas EXPLÍCITAS
    // (mismo criterio que motivos_recepcion e insumo_proveedores).
    'categorias': FamiliaTabla.maestro,
    'proveedor_categorias': FamiliaTabla.maestro,
    'configuracion_negocio': FamiliaTabla.maestro,
    // HU-143: recepciones dejó de ser append-only pura — el total manual
    // (total_recibido + autoría) es editable por el admin, con version +
    // fecha_actualizacion como token LWW. Va a `maestro` (no a
    // `financieraDeEstado`: ahí un cambio de importe remoto se rechaza como
    // conflicto, y acá el importe editado ES el dato que debe sincronizar).
    // Los items/evidencia siguen inmutables por contrato del repositorio.
    'recepciones': FamiliaTabla.maestro,
    // Append-only: evidencia y asientos.
    'adjuntos': FamiliaTabla.appendOnly,
    'historial_precios': FamiliaTabla.appendOnly,
    'imputaciones_pago': FamiliaTabla.appendOnly,
    'movimientos_cuenta_corriente': FamiliaTabla.appendOnly,
    'registros_auditoria': FamiliaTabla.appendOnly,
    // Financieras: importes inmutables, estado derivado sí puede llegar.
    'facturas': FamiliaTabla.financieraDeEstado,
    'pagos': FamiliaTabla.financieraDeEstado,
  };

  /// Familia de [tabla]. Por defecto `maestro` (comportamiento LWW), que es el
  /// más permisivo conocido: una tabla nueva sin clasificar no queda bloqueada.
  static FamiliaTabla familiaDe(String tabla) =>
      _familias[tabla] ?? FamiliaTabla.maestro;

  /// ¿Se aplica la fila remota sobre la local?
  ///
  /// [existeLocal] false ⇒ siempre se aplica (es una alta, no un conflicto).
  ///
  /// **Maestros**: se aplica salvo que haya una mutación local EN VUELO
  /// (`estadoSync == 'pendiente'`) cuya `version` sea mayor o igual a la remota:
  /// ese cambio local es más nuevo y todavía no se pusheó — pisarlo lo perdería
  /// (y encima quedaría marcado 'sincronizado' sin serlo, el bug original).
  ///
  /// **Append-only**: nunca se sobrescribe lo que ya existe.
  ///
  /// **Financieras**: solo si NO cambian los importes ([importesCoinciden]).
  static bool debeAplicarRemoto({
    required FamiliaTabla familia,
    required bool existeLocal,
    String? estadoSyncLocal,
    int? versionLocal,
    int? versionRemota,
    bool importesCoinciden = true,
  }) {
    if (!existeLocal) return true;

    switch (familia) {
      case FamiliaTabla.appendOnly:
        return false;

      case FamiliaTabla.financieraDeEstado:
        // El estado (pendiente→pagada) puede venir del servidor; los importes no.
        if (!importesCoinciden) return false;
        return !_pendienteLocalGana(
          estadoSyncLocal,
          versionLocal,
          versionRemota,
        );

      case FamiliaTabla.maestro:
        return !_pendienteLocalGana(
          estadoSyncLocal,
          versionLocal,
          versionRemota,
        );
    }
  }

  /// `true` si hay un cambio local sin pushear al menos tan nuevo como el remoto.
  static bool _pendienteLocalGana(
    String? estadoSyncLocal,
    int? versionLocal,
    int? versionRemota,
  ) {
    if (estadoSyncLocal != 'pendiente') return false;
    // Sin versiones comparables se protege el cambio local en vuelo (fail-safe:
    // preferimos conservar el dato del usuario y que el push lo resuelva).
    if (versionLocal == null || versionRemota == null) return true;
    return versionLocal >= versionRemota;
  }

  /// ¿La llegada de esta fila remota debe registrarse como CONFLICTO?
  ///
  /// Solo cuando había algo local que defender: una mutación en vuelo que se
  /// descarta, o una divergencia sobre un dato inmutable. Que el pull traiga
  /// novedades sobre filas ya sincronizadas es el caso normal, no un conflicto.
  static bool esConflicto({
    required FamiliaTabla familia,
    required bool existeLocal,
    required bool seAplico,
    String? estadoSyncLocal,
    bool contenidoDivergente = false,
  }) {
    if (!existeLocal) return false;
    if (familia == FamiliaTabla.appendOnly) return contenidoDivergente;
    if (!seAplico) return true; // se rechazó el remoto: hay dos versiones vivas
    // Se aplicó el remoto pisando un cambio local en vuelo.
    return estadoSyncLocal == 'pendiente';
  }
}
