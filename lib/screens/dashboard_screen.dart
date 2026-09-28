import 'dart:async';

import 'package:insuma/constants/politica_password.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_permisos.dart';
import '../services/servicio_gestion_equipo.dart';
import '../services/servicio_pedidos_recurrentes.dart';
import 'widgets/resetear_password_dialog.dart';
import 'widgets/confirmar_baja_dialog.dart';
import '../theme/insuma_colors.dart';
import '../main.dart';
import '../controllers/controlador_dashboard.dart';
import 'pedidos_tab.dart';
import 'recepciones_tab.dart';
import 'proveedores_tab.dart';
import 'recetas_tab.dart';
import 'metricas_tab.dart';
import 'configuracion/pantalla_configuracion.dart';
import 'dashboard/navegacion_dashboard.dart';
import 'dashboard/widgets/menu_lateral.dart';
import '../utils/formatos_entrada.dart';
import '../utils/sanitizador_texto.dart';

/// Pantalla principal adaptativa que contiene el Dashboard de INSUMA.
/// Incluye barra de navegación fija y control de perfiles de usuario (Admin/Cocinero).
class PantallaDashboard extends StatefulWidget {
  const PantallaDashboard({super.key});

  @override
  State<PantallaDashboard> createState() => _PantallaDashboardState();
}

class _PantallaDashboardState extends State<PantallaDashboard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ControladorDashboard>().cargarInfoNegocioYUsuario();
      _generarEntregasRecurrentes();
    });
  }

  /// HU-013: evalúa las agendas y materializa las entregas que correspondan.
  ///
  /// Va acá y no en `main()` porque es el ÚNICO punto que cubre las tres formas
  /// de entrar a un negocio: sesión guardada, login en la misma corrida, y el
  /// superadmin que cambia de negocio sin reiniciar la app.
  ///
  /// Se dispara DESPUÉS del primer frame, así que no retrasa el arranque; y es
  /// idempotente por construcción, así que correrlo de más no rompe nada — que
  /// es lo que permite lanzarlo sin esperar a que termine el pull. Un negocio
  /// recién descargado va a evaluar de nuevo en el próximo arranque.
  void _generarEntregasRecurrentes() {
    final negocioId = context.read<ServicioSesion>().negocioId;
    if (negocioId.isEmpty) return;
    // Sin `await`: el generador no bloquea la pantalla. Sus errores se loguean
    // adentro, pero se atrapa igual para que una excepción inesperada no quede
    // como un future sin capturar.
    unawaited(
      context.read<ServicioPedidosRecurrentes>().evaluar(negocioId).catchError((
        Object e,
      ) {
        debugPrint('[AGENDA] Falló la evaluación al entrar: $e');
        return const ResultadoEvaluacion();
      }),
    );
  }

  /// Muestra el panel de gestión del equipo. Sólo se llega acá si el rol tiene el
  /// permiso `gestionarEquipo`: el botón NO se renderiza para el cocinero (HU-077),
  /// y ya no existe ninguna elevación por PIN que permita saltear ese control.
  Future<void> _mostrarPanelUsuarios() async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Consumer<ControladorDashboard>(
          builder: (context, ctrl, child) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.7,
              maxChildSize: 0.9,
              builder: (context, scrollController) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20.0,
                    vertical: 16.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Gestionar Equipo de Cocina',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () => _mostrarAgregarUsuarioDialog(),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.black,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              '+ Agregar',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: ctrl.cargandoUsuarios
                            ? const Center(child: CircularProgressIndicator())
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: ctrl.usuariosNegocio.length,
                                itemBuilder: (context, index) {
                                  final usr = ctrl.usuariosNegocio[index];
                                  // HU-054: mismo criterio que la cabecera. Acá
                                  // importa más: es la pantalla donde el admin
                                  // decide a quién dar de baja, así que rotular
                                  // "Operador / Cocinero" a alguien que tiene
                                  // todos los permisos desinforma justo en el
                                  // momento de una acción destructiva.
                                  final mandaEnElNegocio = Permisos.puede(
                                    usr.rol,
                                    Permiso.gestionarEquipo,
                                  );
                                  return Card(
                                    elevation: 0,
                                    color: Colors.grey[50],
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: mandaEnElNegocio
                                            ? Colors.black
                                            : Colors.grey[300],
                                        foregroundColor: mandaEnElNegocio
                                            ? Colors.white
                                            : Colors.black87,
                                        child: Icon(
                                          mandaEnElNegocio
                                              ? Icons.lock
                                              : Icons.person,
                                          size: 18,
                                        ),
                                      ),
                                      title: Text(
                                        usr.nombre,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.black87,
                                        ),
                                      ),
                                      subtitle: Text(
                                        Permisos.etiquetaDeRol(usr.rol),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // HU-076: resetear la contraseña del miembro.
                                          IconButton(
                                            tooltip: 'Resetear contraseña',
                                            icon: const Icon(
                                              Icons.key_outlined,
                                              color: Colors.black54,
                                            ),
                                            onPressed: () =>
                                                _resetearPassword(usr),
                                          ),
                                          if (ctrl.usuariosNegocio.length >
                                              1) // no borrar el único usuario
                                            IconButton(
                                              tooltip: 'Eliminar usuario',
                                              icon: const Icon(
                                                Icons.delete_outline,
                                                color: Colors.redAccent,
                                              ),
                                              onPressed: () =>
                                                  _eliminarUsuario(usr),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// Muestra el modal para agregar usuario.
  void _mostrarAgregarUsuarioDialog() {
    String nombre = '';
    String rol = 'cocinero';
    String email = '';
    String password = '';
    String passwordConfirm = '';
    String? error;
    bool ocultarPassword = true;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // HU-055: ancho fijo y relativo al dispositivo para que el form no crezca al tipear.
            final anchoForm = MediaQuery.of(context).size.width < 460
                ? MediaQuery.of(context).size.width * 0.9
                : 420.0;
            return AlertDialog(
              backgroundColor: Colors.white,
              title: const Text(
                'Agregar Nuevo Usuario',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              content: SizedBox(
                width: anchoForm,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        inputFormatters: FormatosEntrada.texto(
                          maxLongitud: SanitizadorTexto.maxLongitudNombre,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Nombre Completo',
                        ),
                        style: const TextStyle(color: Colors.black),
                        onChanged: (v) => nombre = v,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        // #215: sin esto el dropdown se mide por su ítem más ancho e
                        // ignora el ancho disponible: desborda en pantalla de teléfono.
                        isExpanded: true,
                        initialValue: rol,
                        decoration: const InputDecoration(
                          labelText: 'Rol del Usuario',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'cocinero',
                            child: Text('Operador / Cocinero'),
                          ),
                          DropdownMenuItem(
                            value: 'admin',
                            child: Text('Administrador'),
                          ),
                        ],
                        onChanged: (v) =>
                            setModalState(() => rol = v ?? 'cocinero'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Correo Electrónico',
                        ),
                        style: const TextStyle(color: Colors.black),
                        keyboardType: TextInputType.emailAddress,
                        inputFormatters: FormatosEntrada.email(),
                        onChanged: (v) => email = v,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: InputDecoration(
                          labelText: 'Contraseña (mínimo 10 caracteres)',
                          // HU-056: toggle ver/ocultar para que el admin verifique lo que tipea.
                          suffixIcon: IconButton(
                            icon: Icon(
                              ocultarPassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 20,
                            ),
                            tooltip: ocultarPassword ? 'Mostrar' : 'Ocultar',
                            onPressed: () => setModalState(
                              () => ocultarPassword = !ocultarPassword,
                            ),
                          ),
                        ),
                        style: const TextStyle(color: Colors.black),
                        obscureText: ocultarPassword,
                        onChanged: (v) => password = v,
                      ),
                      const SizedBox(height: 12),
                      // HU-056: confirmación para evitar errores de tipeo al comunicar la clave.
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Confirmar contraseña',
                        ),
                        style: const TextStyle(color: Colors.black),
                        obscureText: ocultarPassword,
                        onChanged: (v) => passwordConfirm = v,
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          error!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (nombre.trim().isEmpty) {
                      setModalState(() => error = 'El nombre es requerido.');
                      return;
                    }
                    final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');
                    if (!emailRegex.hasMatch(email.trim())) {
                      setModalState(
                        () => error = 'El correo electrónico no es válido.',
                      );
                      return;
                    }
                    if (password.length < PoliticaPassword.longitudMinima) {
                      setModalState(
                        () => error =
                            'La contraseña debe tener al menos ${PoliticaPassword.longitudMinima} caracteres.',
                      );
                      return;
                    }
                    if (password != passwordConfirm) {
                      setModalState(
                        () => error = 'Las contraseñas no coinciden.',
                      );
                      return;
                    }
                    final ctrl = context.read<ControladorDashboard>();
                    final navigator = Navigator.of(context);

                    // HU-087: el alta crea una cuenta en la nube; devuelve el mensaje
                    // de error real (email en uso, sin conexión, etc.) o null si OK.
                    // HU-137: se guardan SANEADOS. El email iba sin trim aunque se
                    // validaba con trim: un espacio al final quedaba grabado en la
                    // cuenta y después el login por email no encontraba la fila.
                    final errorAlta = await ctrl.crearUsuario(
                      nombre: SanitizadorTexto.limpiar(
                        nombre,
                        maxLongitud: SanitizadorTexto.maxLongitudNombre,
                      ),
                      rol: rol,
                      email: SanitizadorTexto.limpiar(email),
                      password: password,
                    );

                    if (errorAlta == null) {
                      navigator.pop();
                    } else {
                      setModalState(() => error = errorAlta);
                    }
                  },
                  child: const Text('Agregar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Resetea la contraseña de un miembro del equipo (HU-076). La vista sólo abre el
  /// diálogo y delega: toda la lógica vive en el service, y la autorización real es
  /// server-side (Edge Function `resetear-password`).
  Future<void> _resetearPassword(Usuario usuario) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final datos = await showDialog<DatosResetPassword>(
      context: context,
      builder: (_) => ResetearPasswordDialog(
        nombreMiembro: usuario.nombre,
        minPassword: ServicioGestionEquipo.minPassword,
      ),
    );
    if (datos == null || !mounted) return; // canceló

    final ctrl = context.read<ControladorDashboard>();
    final error = await ctrl.resetearPassword(
      usuarioId: usuario.id,
      nuevaPassword: datos.nuevaPassword,
      passwordAdmin: datos.passwordAdmin,
    );

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(
          error ??
              'Listo. ${usuario.nombre} ya puede entrar con la contraseña nueva; '
                  'la anterior dejó de servir.',
        ),
        backgroundColor: error == null
            ? Colors.green.shade700
            : Colors.redAccent,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// Da de baja a un usuario (HU-076 Fase 3): banea su cuenta Auth y revoca sus
  /// sesiones (no sólo `activo=false`). Pide la contraseña del admin para reconfirmar.
  Future<void> _eliminarUsuario(Usuario usuario) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final passwordAdmin = await showDialog<String>(
      context: context,
      builder: (context) => ConfirmarBajaDialog(nombreMiembro: usuario.nombre),
    );
    if (passwordAdmin == null) return; // canceló

    if (!mounted) return;
    final ctrl = context.read<ControladorDashboard>();
    final error = await ctrl.eliminarUsuario(
      usuarioId: usuario.id,
      passwordAdmin: passwordAdmin,
    );
    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(error ?? 'Usuario dado de baja.'),
        backgroundColor: error == null
            ? Colors.green.shade700
            : Colors.redAccent,
      ),
    );
  }

  /// SuperAdmin (HU-037): vuelve a su panel de negocios SIN cerrar la sesión.
  /// El ruteo reactivo (PantallaInicial) muestra el panel al quedar sin negocio activo.
  Future<void> _salirDeNegocio() async {
    await Provider.of<ServicioSesion>(context, listen: false).salirDeNegocio();
  }

  /// Cierra sesión de la cuenta actual.
  Future<void> _cerrarSesion() async {
    final navigator = Navigator.of(context);
    final sesion = Provider.of<ServicioSesion>(context, listen: false);
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Cerrar Sesión',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '¿Quiere salir de la cuenta de su negocio? Los datos locales permanecerán guardados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Salir'),
          ),
        ],
      ),
    );

    if (confirmar == true) {
      // HU-076: cerrar también la sesión de Supabase, no sólo la local. Si no, el
      // token sigue vigente (~1h) y, tras un reset de contraseña, la clave vieja
      // seguiría entrando en el próximo login (haySesion cortaría la re-verificación).
      // Best-effort: si no hay conexión, igual se cierra la sesión local.
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {
        /* sin conexión: igual cerramos la sesión local */
      }
      await sesion.cerrarSesion();
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const PantallaInicial()),
      );
    }
  }

  /// Mapea cada pestaña visible a su pantalla (View).
  Widget _pantallaDe(PestanaDashboard pestana) {
    switch (pestana) {
      case PestanaDashboard.pedidos:
        return const PestanaPedidos();
      case PestanaDashboard.recepciones:
        return const PestanaRecepciones();
      case PestanaDashboard.proveedores:
        return const PestanaProveedores();
      case PestanaDashboard.recetas:
        return const PestanaRecetas();
      case PestanaDashboard.metricas:
        return const PestanaMetricas();
    }
  }

  /// Mapea cada pestaña visible a su ítem de la barra de navegación.
  BottomNavigationBarItem _itemDe(PestanaDashboard pestana) {
    switch (pestana) {
      case PestanaDashboard.pedidos:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.shopping_cart_outlined),
          activeIcon: Icon(
            Icons.shopping_cart,
            color: InsumaColors.primaryBlue,
          ),
          label: 'Pedidos',
        );
      case PestanaDashboard.recepciones:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.inventory_2_outlined),
          activeIcon: Icon(Icons.inventory_2, color: InsumaColors.primaryBlue),
          label: 'Recepciones',
        );
      case PestanaDashboard.proveedores:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.local_shipping_outlined),
          activeIcon: Icon(
            Icons.local_shipping,
            color: InsumaColors.primaryBlue,
          ),
          label: 'Proveedores',
        );
      case PestanaDashboard.recetas:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.restaurant_menu),
          activeIcon: Icon(
            Icons.restaurant_menu,
            color: InsumaColors.primaryBlue,
          ),
          label: 'Recetas',
        );
      case PestanaDashboard.metricas:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.bar_chart_outlined),
          activeIcon: Icon(Icons.bar_chart, color: InsumaColors.primaryBlue),
          label: 'Métricas',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controlador = context.watch<ControladorDashboard>();
    final sesion = context.watch<ServicioSesion>();
    // El rol de la sesión decide TODOS los permisos. HU-077: no hay elevación,
    // así que un cocinero es siempre cocinero.
    final rol = sesion.usuarioRol;
    final puedeVerFinanzas = Permisos.puede(rol, Permiso.verFinanzas);
    // HU-054: gobierna el botón de Equipo Y la apariencia de la cabecera. Antes
    // el avatar salía de `rol == 'admin'`: con esa comparación literal, al
    // SuperAdmin —que tiene todos los permisos— se le pintaba el ícono gris de
    // persona, el del cocinero, al lado de un texto que dice "SuperAdmin".
    final puedeGestionarEquipo = Permisos.puede(rol, Permiso.gestionarEquipo);

    // HU-053: la pestaña Métricas solo se renderiza para quien puede ver finanzas.
    // Para el cocinero NO se instancia PestanaMetricas, así que ni siquiera se
    // disparan sus consultas.
    final pestanas = pestanasVisibles(puedeVerFinanzas: puedeVerFinanzas);
    final List<Widget> pantallas = pestanas.map(_pantallaDe).toList();

    final indiceValido = controlador.indiceSeleccionado >= pantallas.length
        ? 0
        : controlador.indiceSeleccionado;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        // HU-054: el avatar es el segundo acceso al panel de configuración (el
        // otro es el menú lateral). Era decorativo: se tocaba y no pasaba nada,
        // que es donde todo el mundo busca primero sus preferencias.
        leading: Padding(
          padding: const EdgeInsets.only(left: 16.0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const PantallaConfiguracion(),
                ),
              ),
              child: Tooltip(
                message: 'Configuración',
                child: CircleAvatar(
                  backgroundColor: puedeGestionarEquipo
                      ? Colors.black
                      : Colors.grey[200],
                  foregroundColor: puedeGestionarEquipo
                      ? Colors.white
                      : Colors.black87,
                  child: Icon(
                    puedeGestionarEquipo ? Icons.lock : Icons.person,
                    size: 16,
                  ),
                ),
              ),
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              controlador.nombreNegocio,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              // HU-054: vía `etiquetaDeRol` y no `esAdmin ? ... : ...`, que
              // mostraba "Cocinero" para el SuperAdmin sin negocio activo.
              'Sesión: ${controlador.nombreUsuarioActivo} '
              '(${Permisos.etiquetaDeRol(sesion.usuarioRol)})',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          // Menú lateral visible para todos los roles (incluye Historial). Las
          // pantallas de admin dentro del menú siguen protegidas por GuardiaPermiso.
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu, color: Colors.black87),
              tooltip: 'Menú',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
          if (sesion.esSuperAdmin)
            IconButton(
              icon: const Icon(Icons.swap_horiz, color: Colors.black87),
              tooltip: 'Cambiar de negocio',
              onPressed: _salirDeNegocio,
            ),
          // HU-077: para el cocinero el botón NO se renderiza (no debe saber que existe).
          if (puedeGestionarEquipo)
            IconButton(
              icon: const Icon(Icons.group_outlined, color: Colors.black87),
              tooltip: 'Gestionar Equipo',
              onPressed: _mostrarPanelUsuarios,
            ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.black87),
            tooltip: 'Cerrar Sesión',
            onPressed: _cerrarSesion,
          ),
        ],
      ),
      endDrawer: const MenuLateral(),
      body: pantallas[indiceValido],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.grey[200]!, width: 0.5)),
        ),
        child: BottomNavigationBar(
          currentIndex: indiceValido,
          onTap: controlador.actualizarIndice,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          selectedItemColor: InsumaColors.primaryBlue,
          unselectedItemColor: Colors.grey[500],
          selectedFontSize: 11,
          unselectedFontSize: 11,
          items: pestanas.map(_itemDe).toList(),
        ),
      ),
    );
  }
}
