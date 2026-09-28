/// Qué acciones ofrece el menú de una tarjeta de pedido, y cuáles están
/// deshabilitadas y por qué (#269).
///
/// Módulo PURO —sin Flutter y sin base de datos— y esa es toda la razón de que
/// exista: la pantalla que monta este menú tiene **cobertura cero**, así que
/// una regla escrita adentro del widget nace sin red. Acá se prueba con un
/// estado y un booleano.
///
/// ## La trampa que este módulo evita
///
/// El gate del superadministrador **no se escribe con `esAdmin`**. Ese getter
/// compara el rol contra el literal `"admin"`, y el superadministrador NO lo
/// es: `esAdmin` le da `false`, así que un `if (esAdmin)` lo dejaría pasar
/// justo al lugar donde no puede escribir.
///
/// Y no escribir no es un no-op: el superadministrador LEE todos los negocios
/// pero no escribe en ninguno (HU-247 le dio sólo lectura). Como la app es
/// offline-first, su acción se guarda local, el push muere con RLS 42501, y le
/// queda un dato divergente que sólo existe en su dispositivo. Por eso la
/// acción se ve **deshabilitada con su motivo** en vez de desaparecer: si
/// desaparece, la próxima persona la vuelve a agregar sin enterarse del porqué.
library;

import 'estados_pedido.dart';
import 'transiciones_pedido.dart';

/// Las dos únicas acciones del menú (decisión del PO del 2026-09-26: nada más
/// se muda ahí).
enum AccionTarjeta { reprogramar, cancelar }

/// Una entrada del menú, ya resuelta.
class OpcionMenuPedido {
  final AccionTarjeta accion;

  /// Lo que se lee en el menú.
  final String etiqueta;

  final bool habilitada;

  /// Por qué no se puede, para mostrarlo al lado. `null` si está habilitada.
  final String? motivo;

  const OpcionMenuPedido({
    required this.accion,
    required this.etiqueta,
    required this.habilitada,
    this.motivo,
  });
}

/// Leyenda única del bloqueo del superadministrador.
///
/// Una sola constante y no un texto por pantalla: es la misma limitación en
/// todos lados, y tres redacciones distintas se leen como tres reglas
/// distintas.
const String motivoSuperAdmin =
    'El superadministrador puede ver, no modificar.';

/// Las opciones del menú para un pedido en [estado].
///
/// Devuelve lista VACÍA cuando no hay nada que ofrecer —un pedido ya recibido,
/// pagado o cancelado— y ahí la tarjeta no dibuja el menú. Un menú de tres
/// puntos que se abre vacío es peor que no tenerlo.
///
/// [esSuperAdmin] llega desde `ServicioSesion.esSuperAdmin` y NUNCA se deduce
/// del rol: ver la nota de la librería.
List<OpcionMenuPedido> opcionesDeMenu(
  String estado, {
  required bool esSuperAdmin,
}) {
  final opciones = <OpcionMenuPedido>[];

  if (TransicionesPedido.esReprogramable(estado)) {
    opciones.add(
      OpcionMenuPedido(
        accion: AccionTarjeta.reprogramar,
        // "Cambiar fecha" y no "Reprogramar": también sirve para PONERLE una
        // fecha a una entrega que no tiene, que no es reprogramar nada.
        etiqueta: 'Cambiar fecha de entrega',
        habilitada: !esSuperAdmin,
        motivo: esSuperAdmin ? motivoSuperAdmin : null,
      ),
    );
  }

  if (TransicionesPedido.esCancelable(estado)) {
    opciones.add(
      OpcionMenuPedido(
        accion: AccionTarjeta.cancelar,
        etiqueta: estado == EstadosPedido.enEspera
            ? 'Cancelar entrega'
            : 'Cancelar pedido',
        habilitada: !esSuperAdmin,
        motivo: esSuperAdmin ? motivoSuperAdmin : null,
      ),
    );
  }

  return opciones;
}

/// Texto de la advertencia de quitarle la fecha a una entrega (#269).
///
/// Vive acá, con las demás reglas, y no en el diálogo: es una decisión de
/// producto —el PO la pidió explícitamente— y tiene que poder probarse sin
/// levantar Flutter.
///
/// Lo que avisa es **contraintuitivo y por eso es obligatorio**: quien saca la
/// fecha suele querer posponer la entrega, y el efecto es el opuesto. Sin
/// fecha, la entrega va a la primera sección de Recepciones y deja de estar
/// sujeta a la ventana de 7 días, así que pasa a verse SIEMPRE.
const String advertenciaQuitarFecha =
    'La entrega va a quedar sin fecha. No se pospone: pasa a la sección '
    '"Sin fecha", arriba de todo en Recepciones, y queda siempre visible '
    'hasta que le pongas una fecha o la recibas.';
