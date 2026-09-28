import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../database/database.dart';
import '../theme/insuma_colors.dart';
import '../controllers/controlador_recibir.dart';
import '../controllers/controlador_ventana_recepciones.dart';
import '../utils/estados_pedido.dart';
import '../utils/fecha_recepcion.dart';
import '../utils/orden_recepciones.dart';
import '../utils/secciones_recepciones.dart';
import '../utils/semaforo_entrega.dart';
import '../utils/ventana_recepciones.dart';
import 'recibir/acciones_pedido_mixin.dart';
import 'recibir/widgets/tarjeta_pedido.dart';
import 'widgets/titulo_seccion.dart';

/// Pantalla de RECEPCIONES: pedidos que el proveedor YA confirmó (`en_espera`) y
/// están listos para recibir físicamente. Separa "pendiente de recibir" de
/// "pendiente de confirmación" (que vive en Pedidos › Activos).
class PestanaRecepciones extends StatefulWidget {
  const PestanaRecepciones({super.key});

  @override
  State<PestanaRecepciones> createState() => _PestanaRecepcionesState();
}

class _PestanaRecepcionesState extends State<PestanaRecepciones>
    with AccionesPedidoMixin {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ctrlRecibir.cargarSesionYPedidos(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ControladorRecibir>();
    if (ctrl.cargando) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // HU-013: el orden lo define el módulo puro `orden_recepciones`: primero
    // los SIN fecha de entrega, después por fecha ascendente, y a igual fecha
    // primero los pedidos normales y luego los recurrentes.
    //
    // ⚠ CAMBIO VISIBLE para quien ya usa la pantalla: antes heredaba el
    // `fechaActualizacion DESC` del repositorio, así que cualquier toque a un
    // pedido lo saltaba al tope de la lista. Ese salto desaparece.
    final pendientes = ordenarRecepciones(
      ctrl.pedidos.where((p) => p.estado == EstadosPedido.enEspera).toList(),
    );

    // HU-013: la ventana móvil que pidió el PO. Se aplica DESPUÉS de ordenar y
    // no reordena nada.
    //
    // El día de referencia se reengancha con el reloj en cada build: la app se
    // deja abierta de un día para el otro, y sin esto "los próximos 7 días"
    // seguiría contando desde ayer.
    final ventanaCtrl = context.watch<ControladorVentanaRecepciones>();
    ventanaCtrl.sincronizarConElReloj();
    final ventana = aplicarVentana(
      pendientes,
      hoy: ventanaCtrl.hoy,
      semanas: ventanaCtrl.semanas,
    );

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      body: pendientes.isEmpty
          // Nada de nada: el vacío de siempre.
          ? _vacio()
          : ventana.visibles.isEmpty
          // Hay entregas, pero todas más adelante. Mostrar acá el texto de
          // "no hay entregas" MENTIRÍA, y te mandaría a buscar un pedido
          // que no está perdido.
          ? _vacioEnLaVentana(ventana, ventanaCtrl)
          : _listado(ventana, ventanaCtrl),
    );
  }

  /// Encabezado: hasta dónde llega la ventana y cuántas entra.
  ///
  /// El texto lo arma el módulo puro: el pie muestra el MISMO resumen (#202) y
  /// dos copias del formato se desincronizarían al primer retoque.
  Widget _encabezado(RecepcionesEnVentana v) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Text(
        resumenDeVentana(
          v,
          semanas: context.read<ControladorVentanaRecepciones>().semanas,
        ),
        style: const TextStyle(fontSize: 12, color: Colors.black54),
      ),
    );
  }

  /// Pie del listado. SIEMPRE está: un botón que aparece y desaparece sin
  /// explicación se reporta como bug, y con la regla de una entrega pendiente
  /// por agenda lo normal es que no haya nada oculto.
  ///
  /// Sin spinner a propósito: los pedidos ya están todos en el dispositivo, así
  /// que estirar la ventana tarda cero. Un spinner sería mentir.
  Widget _pie(RecepcionesEnVentana v, ControladorVentanaRecepciones ctrl) {
    if (!v.hayMasAdelante) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 24),
        child: Text(
          'No hay más entregas después del ${FechaRecepcion.formatear(v.hasta)}.',
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: ctrl.verMas,
            icon: const Icon(Icons.expand_more, size: 18),
            label: Text(
              'Ver 7 días más  ·  hay ${v.ocultas} '
              '${v.ocultas == 1 ? "entrega" : "entregas"} más adelante',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          // El MISMO resumen que el encabezado, acá abajo (#202): el botón está
          // al pie y el dato que ese botón cambia estaba sólo arriba, así que
          // para saber hasta cuándo se está viendo había que volver al
          // principio de la lista. Se repite a propósito, no se mueve: al abrir
          // la pestaña el de arriba sigue siendo la referencia.
          //
          // Va sólo en esta rama y no en la de "no hay más entregas", que ya
          // nombra la misma fecha con otras palabras.
          Text(
            resumenDeVentana(v, semanas: ctrl.semanas),
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Hay entregas, pero ninguna cae dentro de la ventana.
  Widget _vacioEnLaVentana(
    RecepcionesEnVentana v,
    ControladorVentanaRecepciones ctrl,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.event_available_outlined,
              size: 48,
              color: Colors.grey[300],
            ),
            const SizedBox(height: 12),
            Text(
              'Nada entre hoy y el ${FechaRecepcion.formatear(v.hasta)}',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Tenés ${v.ocultas} ${v.ocultas == 1 ? "entrega" : "entregas"} '
              'más adelante.',
              style: TextStyle(color: Colors.grey[400], fontSize: 11),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: ctrl.verMas,
              icon: const Icon(Icons.expand_more, size: 18),
              label: const Text(
                'Ver 7 días más',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vacio() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.local_shipping_outlined,
            size: 48,
            color: Colors.grey[300],
          ),
          const SizedBox(height: 12),
          Text(
            'No hay entregas por recibir',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            'Cuando confirmes un pedido activo, aparecerá acá.',
            style: TextStyle(color: Colors.grey[400], fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// Una entrega. Se extrajo del `itemBuilder` en #277: con las secciones, el
  /// builder pasó a decidir QUÉ fila dibuja, y la tarjeta entera adentro de esa
  /// decisión dejaba un `switch` de sesenta líneas donde no se veía la rama.
  Widget _tarjeta(Pedido ped, ControladorVentanaRecepciones ctrl) {
    return TarjetaPedido(
      pedido: ped,
      puedeVerFinanzas: puedeVerFinanzas,
      // La DECISIÓN se toma acá, no en la tarjeta: mirando también el
      // estado. Ver la nota de `serieFrenada`.
      serieFrenada: serieFrenada(
        ped,
        hoy: ctrl.hoy,
        estadoPendiente: EstadosPedido.enEspera,
      ),
      // #268: igual que `serieFrenada`, la decisión se toma ACÁ y la
      // tarjeta sólo la pinta. `ctrl.hoy` y no `DateTime.now()`: es el
      // mismo día para toda la lista y el que se reengancha al cruzar la
      // medianoche, así que ninguna fila se evalúa contra otro día.
      semaforo: semaforoDePedido(
        ped,
        hoy: ctrl.hoy,
        estadoPendiente: EstadosPedido.enEspera,
      ),
      // #269: "Cancelar" se mudó al menú del encabezado. Además de agrupar las
      // dos acciones que no son el camino principal, le devuelve lugar a esta
      // botonera, que desbordaba a 360 dp (#180).
      menu: menuDePedido(ped),
      acciones: [
        IconButton(
          tooltip: 'Chatear por WhatsApp con el proveedor',
          icon: const Icon(
            Icons.chat_bubble_outline,
            color: Color(0xFF25D366),
            size: 18,
          ),
          onPressed: () => abrirChatWhatsApp(ped),
        ),
        TextButton.icon(
          icon: const Icon(Icons.check_box_outlined, size: 14),
          label: const Text(
            'Verificar y Recibir',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
          onPressed: () => abrirVerificacionRecepcion(ped),
        ),
      ],
    );
  }

  /// #277: el pie de "Vencidos" cuando hay más atrasados que el tope.
  ///
  /// Dice el número en el botón —no "ver más"— para que la decisión de tocarlo
  /// se tome sabiendo qué hay del otro lado. Mismo criterio que el "Ver 7 días
  /// más · hay 3 entregas más adelante" del pie de la lista.
  Widget _verRestantes(int cuantos, ControladorVentanaRecepciones ctrl) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: ctrl.expandirVencidos,
        icon: const Icon(Icons.expand_more, size: 18),
        label: Text(
          cuantos == 1
              ? 'Ver la entrega atrasada restante'
              : 'Ver las $cuantos entregas atrasadas restantes',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _listado(
    RecepcionesEnVentana ventana,
    ControladorVentanaRecepciones ctrl,
  ) {
    // #277: el agrupamiento lo decide el módulo puro. Acá no queda ninguna
    // regla: el builder sólo pinta la fila que le toca.
    final filas = aplanarEnSecciones(
      ventana.visibles,
      hoy: ctrl.hoy,
      vencidosExpandidos: ctrl.vencidosExpandidos,
    );
    // +2: el encabezado arriba y el pie abajo. Los dos hablan de la VENTANA
    // (cuántos días se proyectan), no de las secciones, así que quedan fuera
    // del aplanado.
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: filas.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _encabezado(ventana);
        if (index == filas.length + 1) return _pie(ventana, ctrl);
        // `switch` exhaustivo sobre una jerarquía `sealed`: agregar una
        // variante nueva a `ItemLista` no compila hasta que se decide acá cómo
        // se dibuja. Con un `default`, esa fila nueva no se pintaría y nadie
        // se enteraría.
        return switch (filas[index - 1]) {
          final SeparadorSeccion s => TituloSeccion(
            s.titulo,
            cantidad: s.cantidad,
          ),
          final TarjetaDeItem t => _tarjeta(t.pedido, ctrl),
          final BotonVerRestantes b => _verRestantes(b.cuantos, ctrl),
        };
      },
    );
  }
}
