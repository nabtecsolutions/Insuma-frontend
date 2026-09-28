/// Los pasos de un pedido: quién hizo cada uno y cuándo (#273).
///
/// Módulo PURO —sin Flutter y sin base de datos propia—: recibe las filas ya
/// leídas y devuelve la lista de pasos lista para pintar. La pantalla que lo
/// muestra no decide nada.
///
/// ## Por qué esto NO es el registro de auditoría
///
/// Se arma **sólo con columnas de fila que ya sincronizan ida y vuelta**. Eso no
/// es una preferencia: `registros_auditoria` SUBE y NO BAJA en el pull, así que
/// cada dispositivo tiene únicamente sus propias filas. Una trazabilidad armada
/// desde ahí mostraría cosas distintas en cada teléfono, que es peor que no
/// mostrar nada.
///
/// El registro genérico de auditoría es #61, y es otra cosa.
///
/// ## Lo que falta y se dice en voz alta
///
/// **"Confirmado por el proveedor" no se puede mostrar.** Ese hecho existe sólo
/// como fila de `registros_auditoria`, por el motivo de arriba. No se inventa un
/// paso vacío ni se deduce del estado: el pedido pasa a `en_espera` y nadie sabe
/// quién ni cuándo lo confirmó desde otro dispositivo. Aparece como paso
/// **ausente y explicado**, no como un hueco.
///
/// ## Un paso sin fecha NO se esconde
///
/// Los pasos que todavía no ocurrieron —o que son anteriores a esta versión y
/// nunca se registraron— se devuelven igual, con `cuando` en `null`. Esconderlos
/// dejaría una lista que se lee como completa y no lo está: quien mire no
/// podría distinguir "esto no pasó" de "esto no se guarda".
library;

import '../database/database.dart';

/// Los pasos del ciclo de un pedido, en el orden en que ocurren.
enum PasoPedido {
  creado,
  enviado,

  /// Existe pero NO se puede completar: ver la nota de la librería.
  confirmado,
  recibido,
  facturado,
  pagado,
}

/// Por qué un paso no tiene datos.
enum MotivoSinDato {
  /// Todavía no pasó.
  noOcurrio,

  /// Pasó, pero este dispositivo no puede saberlo: el hecho vive sólo en
  /// `registros_auditoria`, que no baja en el pull.
  noSeSincroniza,

  /// Pasó, pero el pedido es anterior a la versión que empezó a registrarlo.
  anteriorAlRegistro,
}

/// Un paso del pedido.
class PasoTrazabilidad {
  final PasoPedido paso;

  /// UUID de quien lo hizo, o `null`.
  final String? usuarioId;

  /// Nombre para mostrar, ya resuelto. `null` si no se pudo.
  final String? nombre;

  final DateTime? cuando;

  /// Sólo cuando [cuando] es `null`.
  final MotivoSinDato? motivo;

  const PasoTrazabilidad({
    required this.paso,
    this.usuarioId,
    this.nombre,
    this.cuando,
    this.motivo,
  });

  bool get tieneDato => cuando != null;
}

/// Un hecho leído de otra tabla (factura, pago).
typedef HechoDePedido = ({String? usuarioId, DateTime? cuando});

/// Arma los pasos de [pedido].
///
/// [recepciones] son las de ese pedido; se usa la **primera** por número, que es
/// la que responde "cuándo llegó por primera vez". Las parciales siguientes no
/// se listan acá: eso es el detalle de recepciones, que ya tiene su propio
/// bloque y su propio widget.
///
/// [resolverNombre] traduce un UUID a nombre contra la tabla local de usuarios.
/// Se inyecta en vez de leerse acá adentro para que el módulo siga siendo puro,
/// y puede devolver `null`: un usuario dado de baja, o que este dispositivo
/// nunca bajó, es un caso normal y no un error.
List<PasoTrazabilidad> trazabilidadDe({
  required Pedido pedido,
  required List<Recepcion> recepciones,
  HechoDePedido? factura,
  HechoDePedido? pago,
  required String? Function(String uuid) resolverNombre,
}) {
  /// Nombre a mostrar: se prefiere el DENORMALIZADO de la fila.
  ///
  /// No es redundancia: el denormalizado se guardó con el nombre que la persona
  /// tenía EN ESE MOMENTO, y resolver el UUID hoy devolvería el nombre actual.
  /// Para una trazabilidad, lo primero es más correcto. Y además sobrevive a que
  /// el usuario se haya dado de baja.
  String? nombreDe(String? denormalizado, String? uuid) {
    if (denormalizado != null && denormalizado.isNotEmpty) return denormalizado;
    return uuid == null ? null : resolverNombre(uuid);
  }

  final primeraRecepcion = recepciones.isEmpty
      ? null
      : recepciones.reduce(
          (a, b) => a.numeroRecepcion <= b.numeroRecepcion ? a : b,
        );

  return [
    PasoTrazabilidad(
      paso: PasoPedido.creado,
      usuarioId: pedido.creadoPor,
      nombre: nombreDe(pedido.creadoPorNombre, pedido.creadoPor),
      cuando: pedido.fechaCreacion,
    ),
    PasoTrazabilidad(
      paso: PasoPedido.enviado,
      usuarioId: pedido.enviadoPor,
      nombre: nombreDe(pedido.enviadoPorNombre, pedido.enviadoPor),
      cuando: pedido.fechaEnvio,
      // Un pedido que ya salió de borrador y no tiene fecha de envío es de
      // antes de #273: el hecho ocurrió, pero nadie lo guardaba. Decirlo es
      // distinto de decir "todavía no se envió", y la diferencia importa.
      motivo: pedido.fechaEnvio != null
          ? null
          : (pedido.estado == 'borrador'
                ? MotivoSinDato.noOcurrio
                : MotivoSinDato.anteriorAlRegistro),
    ),
    const PasoTrazabilidad(
      paso: PasoPedido.confirmado,
      motivo: MotivoSinDato.noSeSincroniza,
    ),
    PasoTrazabilidad(
      paso: PasoPedido.recibido,
      usuarioId: primeraRecepcion?.recepcionadoPor,
      nombre: primeraRecepcion == null
          ? null
          : nombreDe(
              primeraRecepcion.recepcionadoPorNombre,
              primeraRecepcion.recepcionadoPor,
            ),
      cuando: primeraRecepcion?.fechaRecepcion,
      motivo: primeraRecepcion == null ? MotivoSinDato.noOcurrio : null,
    ),
    PasoTrazabilidad(
      paso: PasoPedido.facturado,
      usuarioId: factura?.usuarioId,
      // Sin denormalizado: `facturas` guarda sólo el UUID.
      nombre: factura?.usuarioId == null
          ? null
          : resolverNombre(factura!.usuarioId!),
      cuando: factura?.cuando,
      motivo: factura?.cuando == null ? MotivoSinDato.noOcurrio : null,
    ),
    PasoTrazabilidad(
      paso: PasoPedido.pagado,
      usuarioId: pago?.usuarioId,
      nombre: pago?.usuarioId == null ? null : resolverNombre(pago!.usuarioId!),
      cuando: pago?.cuando,
      motivo: pago?.cuando == null ? MotivoSinDato.noOcurrio : null,
    ),
  ];
}

/// Cómo se le nombra cada paso al usuario.
String etiquetaPaso(PasoPedido paso) {
  switch (paso) {
    case PasoPedido.creado:
      return 'Creado';
    case PasoPedido.enviado:
      return 'Enviado al proveedor';
    case PasoPedido.confirmado:
      return 'Confirmado por el proveedor';
    case PasoPedido.recibido:
      return 'Recibido';
    case PasoPedido.facturado:
      return 'Facturado';
    case PasoPedido.pagado:
      return 'Pagado';
  }
}

/// Qué se muestra en lugar de la fecha cuando el paso no tiene dato.
///
/// Los tres textos dicen cosas DISTINTAS a propósito. "Todavía no" es el estado
/// normal de un pedido en curso; los otros dos son limitaciones de la app, y
/// confundirlos haría que alguien busque un dato que no existe.
String textoSinDato(MotivoSinDato motivo) {
  switch (motivo) {
    case MotivoSinDato.noOcurrio:
      return 'Todavía no';
    case MotivoSinDato.noSeSincroniza:
      return 'No se sincroniza entre dispositivos';
    case MotivoSinDato.anteriorAlRegistro:
      return 'Sin registrar (anterior a esta versión)';
  }
}
