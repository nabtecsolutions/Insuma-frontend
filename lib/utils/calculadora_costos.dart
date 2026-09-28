/// Estado del semáforo de FoodCost (RN-010 / HU-021).
enum SemaforoFoodCost { verde, amarillo, rojo, indefinido }

/// Resultado del cálculo de FoodCost: porcentaje y color del semáforo.
class ResultadoFoodCost {
  final double foodCostFraccion; // 0.32 = 32%
  final SemaforoFoodCost semaforo;
  const ResultadoFoodCost(this.foodCostFraccion, this.semaforo);

  double get foodCostPorcentaje => foodCostFraccion * 100.0;
}

/// Por qué la mano de obra dio cero (HU-152).
///
/// Existe para que un cero nunca quede mudo: "Mano de obra: $0" se lee como "no
/// cuesta nada" y el margen se malinterpreta. Cada valor manda a un lugar
/// distinto a resolverlo, que es lo que lo hace útil.
enum AvisoManoDeObra {
  /// Los dos datos están: el número es real.
  ninguno,

  /// El negocio no configuró el costo por hora. Se carga UNA vez y destraba
  /// todas las recetas, así que tiene prioridad sobre el aviso por receta.
  costoHoraSinConfigurar,

  /// Hay costo por hora, pero ESTA receta no declara cuánto lleva elaborarla.
  /// Su costo queda subestimado frente a las que sí lo declaran.
  tiempoSinDeclarar,
}

/// Costo de una receta abierto en sus dos componentes (HU-152).
///
/// El desglose es parte del criterio de la HU, no una comodidad: un costo alto
/// por insumos y uno por tiempo se corrigen de maneras distintas (renegociar con
/// el proveedor vs. cambiar el proceso), y el total solo no permite distinguirlos.
class DesgloseCostoReceta {
  const DesgloseCostoReceta({
    required this.insumos,
    required this.manoDeObra,
    required this.aviso,
  });

  final double insumos;
  final double manoDeObra;
  final AvisoManoDeObra aviso;

  double get total => insumos + manoDeObra;
}

/// Textos de usuario para [AvisoManoDeObra] (HU-152).
///
/// Viven junto al enum y no en cada pantalla para que el listado, el modal y
/// métricas digan EXACTAMENTE lo mismo: si tres pantallas redactan el mismo
/// aviso por su cuenta, tarde o temprano una queda desactualizada y manda al
/// usuario a un lugar equivocado.
class AvisosManoDeObra {
  /// Frase completa, para donde hay lugar (modal de receta).
  static String texto(AvisoManoDeObra aviso) => switch (aviso) {
    AvisoManoDeObra.ninguno => '',
    // Se carga UNA vez y destraba TODAS las recetas: por eso este aviso
    // manda a Configuración y no a editar la receta.
    AvisoManoDeObra.costoHoraSinConfigurar =>
      'Sin costo por hora configurado. Cargalo en Configuración → Negocio '
          'para que el costo incluya la mano de obra.',
    // Acá, en cambio, lo que falta es de ESTA receta.
    AvisoManoDeObra.tiempoSinDeclarar =>
      'Esta receta no declara tiempo de elaboración: su costo queda '
          'subestimado frente a las que sí lo declaran.',
  };
}

class CalculadoraCostos {
  /// Umbrales del semáforo de FoodCost cuando el negocio no configuró los suyos
  /// (RN-010 / HU-021): verde por debajo del 30%, amarillo hasta el 35%.
  ///
  /// Viven acá y NO repetidos como números sueltos porque el mismo par estaba
  /// escrito en tres lugares que nada obligaba a mantener sincronizados: el
  /// `withDefault` de las columnas Drift, los parámetros de [calcularFoodCost] y
  /// el fallback del pull en `servicio_descarga_negocio.dart`. Tres copias de un
  /// número de negocio es una discrepancia esperando la primera vez que alguien
  /// cambie sólo una (#197).
  ///
  /// ⚠️ **CONGELADAS POR EL ESQUEMA: cambiar el número acá NO alcanza.** El
  /// valor también está escrito como DDL en dos lugares que este archivo no
  /// gobierna:
  ///  - el `DEFAULT 0.30` del baseline de Supabase
  ///    (`supabase/migrations/20260621034530_baseline_remote_schema.sql`);
  ///  - el DEFAULT de la columna SQLite de cada dispositivo, que queda fijado
  ///    en el momento de la instalación y NO se reescribe solo.
  ///
  /// O sea: tocar sólo esta constante haría que las instalaciones NUEVAS nazcan
  /// con un default y las viejas conserven el anterior, con el servidor en un
  /// tercero — y nada en CI lo marcaría. Cambiarlo de verdad exige migración de
  /// los dos lados. Lo que estas constantes unifican es el comportamiento del
  /// CÓDIGO (el fallback del pull y el del cálculo), no el DDL.
  static const double umbralVerdePorDefecto = 0.30;
  static const double umbralAmarilloPorDefecto = 0.35;

  /// Abre el costo de una receta en insumos + mano de obra (HU-152).
  ///
  /// La mano de obra es `(minutos / 60) × costoHora`. Los dos parámetros son
  /// NULLABLE a propósito: `null` significa "sin configurar" y es distinto de
  /// cero. Con una columna `default 0` los dos casos serían indistinguibles y no
  /// habría forma de avisar — que es justo lo que pide la HU.
  ///
  /// Un costo por hora de 0 también cuenta como sin configurar: ningún negocio
  /// paga cero la hora, así que ese valor sólo puede venir de un dato que nunca
  /// se cargó de verdad.
  ///
  /// Los negativos se descartan (no restan): un signo menos que se cuela por el
  /// teclado o por un mapeo de sync abarataría la receta, el margen saldría
  /// mejor de lo que es y el precio de carta se fijaría por debajo del costo.
  static DesgloseCostoReceta desglosarCostoReceta({
    required double costoInsumos,
    required double? tiempoElaboracionMinutos,
    required double? costoHoraEmpleado,
  }) {
    final insumos = costoInsumos > 0 ? costoInsumos : 0.0;
    final minutos = (tiempoElaboracionMinutos ?? 0) > 0
        ? tiempoElaboracionMinutos!
        : 0.0;
    final costoHora = (costoHoraEmpleado ?? 0) > 0 ? costoHoraEmpleado! : 0.0;

    if (costoHora == 0) {
      return DesgloseCostoReceta(
        insumos: insumos,
        manoDeObra: 0.0,
        aviso: AvisoManoDeObra.costoHoraSinConfigurar,
      );
    }
    if (minutos == 0) {
      return DesgloseCostoReceta(
        insumos: insumos,
        manoDeObra: 0.0,
        aviso: AvisoManoDeObra.tiempoSinDeclarar,
      );
    }

    return DesgloseCostoReceta(
      insumos: insumos,
      manoDeObra: (minutos / 60.0) * costoHora,
      aviso: AvisoManoDeObra.ninguno,
    );
  }

  /// Calcula el FoodCost y su semáforo (RN-009 / RN-010 / HU-021).
  /// FoodCost = costoPorPorcion / precioVenta. Semáforo configurable por negocio:
  /// verde < [verdeMax]; amarillo [verdeMax]–[amarilloMax]; rojo > [amarilloMax].
  static ResultadoFoodCost calcularFoodCost({
    required double costoPorPorcion,
    required double precioVenta,
    double verdeMax = umbralVerdePorDefecto,
    double amarilloMax = umbralAmarilloPorDefecto,
  }) {
    if (precioVenta <= 0 || costoPorPorcion < 0) {
      return const ResultadoFoodCost(0.0, SemaforoFoodCost.indefinido);
    }
    final fc = costoPorPorcion / precioVenta;
    final SemaforoFoodCost semaforo;
    if (fc < verdeMax) {
      semaforo = SemaforoFoodCost.verde;
    } else if (fc <= amarilloMax) {
      semaforo = SemaforoFoodCost.amarillo;
    } else {
      semaforo = SemaforoFoodCost.rojo;
    }
    return ResultadoFoodCost(fc, semaforo);
  }

  /// Calcula el costo de un ingrediente aplicando merma.
  /// Fórmula: (cantidadNeta / (1.0 - merma)) * costoPorUnidad
  static double costoIngrediente({
    required double cantidadNeta,
    required double desperdicioPorcentaje,
    required double costoPorUnidad,
  }) {
    final merma = desperdicioPorcentaje.clamp(0.0, 0.99);
    return (cantidadNeta / (1.0 - merma)) * costoPorUnidad;
  }

  /// Calcula el margen real: (precioVenta - costo) / precioVenta
  static double margenReal({
    required double precioVenta,
    required double costoPorPorcion,
  }) {
    if (precioVenta <= 0) return 0.0;
    return (precioVenta - costoPorPorcion) / precioVenta;
  }

  /// Calcula el costo por porción: costoTotal / porciones
  static double costoPorPorcion({
    required double costoTotal,
    required double porciones,
  }) {
    if (porciones <= 0) return 0.0;
    return costoTotal / porciones;
  }
}
