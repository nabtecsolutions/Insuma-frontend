import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/controlador_onboarding.dart';
import '../services/servicio_gestion_equipo.dart';
import '../services/servicio_inicializacion.dart';
import 'package:insuma/constants/politica_password.dart';
import 'package:insuma/utils/validador_datos.dart';
import 'package:insuma/utils/formatos_entrada.dart';
import 'package:insuma/utils/sanitizador_texto.dart';
import 'onboarding/widgets/input_glassmorphic.dart';
import 'onboarding/widgets/tarjeta_glass.dart';
import 'onboarding/widgets/tarjeta_plan.dart';
import 'onboarding/widgets/seccion_equipo.dart';
import 'widgets/recuperar_password_dialog.dart';

/// Pantalla de Onboarding en 6 pasos y Login integrado para INSUMA.
/// Diseñada con estética premium, degradados fluidos y tarjetas glassmorphic.
class PantallaOnboarding extends StatefulWidget {
  final VoidCallback alCompletar;

  const PantallaOnboarding({super.key, required this.alCompletar});

  @override
  State<PantallaOnboarding> createState() => _PantallaOnboardingState();
}

class _PantallaOnboardingState extends State<PantallaOnboarding> {
  final PageController _pageController = PageController();

  // Focos para encadenar campos con Enter, saltando botones intermedios (ej: el ícono del ojo).
  final FocusNode _loginPassNode = FocusNode();
  final FocusNode _regEmailNode = FocusNode();
  final FocusNode _regPassNode = FocusNode();
  final FocusNode _regConfirmNode = FocusNode();

  // Variables locales exclusivas del bypass de demostración
  bool _cargandoBypass = false;
  String? _errorBypass;

  @override
  void dispose() {
    _pageController.dispose();
    _loginPassNode.dispose();
    _regEmailNode.dispose();
    _regPassNode.dispose();
    _regConfirmNode.dispose();
    super.dispose();
  }

  // Getters y Setters delegados al ControladorOnboarding (Patrón MVC)
  ControladorOnboarding get _ctrl =>
      Provider.of<ControladorOnboarding>(context, listen: false);

  int get _pasoActual => _ctrl.pasoActual;
  int get _totalPasos => _ctrl.totalPasos;

  String get _tipoNegocio => _ctrl.tipoNegocio;
  set _tipoNegocio(String v) => _ctrl.actualizarTipoNegocio(v);

  String get _codigoInvitacion => _ctrl.codigoInvitacion;
  set _codigoInvitacion(String v) => _ctrl.actualizarCodigoInvitacion(v);

  String get _email => _ctrl.email;
  set _email(String v) => _ctrl.actualizarEmail(v);

  String get _password => _ctrl.password;
  set _password(String v) => _ctrl.actualizarPassword(v);

  String get _confirmarPassword => _ctrl.confirmarPassword;
  set _confirmarPassword(String v) => _ctrl.actualizarConfirmarPassword(v);

  String get _planSeleccionado => _ctrl.planSeleccionado;
  set _planSeleccionado(String v) => _ctrl.actualizarPlanSeleccionado(v);

  List<Map<String, dynamic>> get _usuariosEquipo => _ctrl.usuariosEquipo;

  bool get _mostrarLogin => _ctrl.mostrarLogin;

  bool get _loginCargando => _ctrl.loginCargando;
  String? get _loginError => _ctrl.loginError;

  bool get _cargando => _ctrl.cargando || _cargandoBypass;
  String? get _errorActual => _ctrl.errorActual ?? _errorBypass;

  // Gradiente premium para los fondos (Azul característico de INSUMA)
  final LinearGradient _degradadoFondo = const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF2E86C1), // Azul profundo
      Color(0xFF72BDE8), // Celeste intermedio
      Color(0xFFAED6F1), // Azul claro/luz
    ],
  );

  /// Navega al siguiente paso del Onboarding con micro-animación fluida.
  void _siguientePaso() {
    final ctrl = _ctrl;
    if (_pasoActual < _totalPasos) {
      ctrl.actualizarPaso(_pasoActual + 1);
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finalizarOnboarding();
    }
  }

  /// Navega al paso anterior del Onboarding.
  void _pasoAnterior() {
    final ctrl = _ctrl;
    if (_pasoActual > 1) {
      ctrl.actualizarPaso(_pasoActual - 1);
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// Avanza desde el Paso 1 solo si el nombre del negocio es válido (mismo criterio que el botón).
  void _intentarAvanzarNombre() {
    if (_ctrl.nombreNegocio.trim().isNotEmpty) _siguientePaso();
  }

  /// Valida el código del Paso 3 CONTRA EL BACKEND (HU-075) y sólo avanza si sirve.
  ///
  /// Los códigos de bypass de revisión de tiendas se manejan aparte
  /// ([_verificarBypassOffline]): cargan datos demo y nunca crean una cuenta real,
  /// por eso no pasan por esta validación.
  Future<void> _intentarValidarCodigo() async {
    final limpio = _codigoInvitacion.trim().toUpperCase();
    if (limpio.isEmpty) return;
    if (limpio == 'INSUMA.PRUEBA' || limpio == 'INSUMA.MAGGIE') return;

    final valido = await _ctrl.validarCodigoActivacion();
    if (valido && mounted) _siguientePaso();
  }

  /// Indica si el formulario de registro (Paso 4) está completo y válido.
  bool get _registroCompleto =>
      _ctrl.nombreAdmin.trim().isNotEmpty &&
      ValidadorDatos.validarEmail(_email) &&
      _password.length >= PoliticaPassword.longitudMinima &&
      _password == _confirmarPassword;

  /// Avanza desde el Paso 4 solo si el registro es válido (mismo criterio que el botón).
  void _intentarAvanzarRegistro() {
    if (_registroCompleto) _siguientePaso();
  }

  /// Carga los datos de demostración en modo de prueba local/review si el código ingresado coincide.
  Future<void> _verificarBypassOffline(String codigo) async {
    final limpio = codigo.trim().toUpperCase();
    if (limpio == 'INSUMA.PRUEBA' || limpio == 'INSUMA.MAGGIE') {
      setState(() {
        _cargandoBypass = true;
        _errorBypass = null;
      });
      try {
        final initService = Provider.of<ServicioInicializacion>(
          context,
          listen: false,
        );
        await initService.aplicarSemillaDemostracion();
        widget.alCompletar();
      } catch (e) {
        setState(() {
          _errorBypass = 'Error al cargar los datos semilla: $e';
          _cargandoBypass = false;
        });
      }
    }
  }

  /// Da de alta el negocio: el controlador delega en ServicioRegistroNegocio (HU-075).
  Future<void> _finalizarOnboarding() async {
    final exito = await _ctrl.finalizarOnboarding(widget.alCompletar);

    // El negocio se creó pero algún miembro no (HU-088): se avisa explícitamente en
    // vez de dejarlo pasar en silencio, porque esos integrantes NO van a poder entrar.
    final noCreados = _ctrl.avisoMiembrosNoCreados;
    if (!exito || noCreados.isEmpty || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        backgroundColor: Colors.orange.shade800,
        content: Text(
          'Tu negocio se creó, pero no pudimos dar de alta a: '
          '${noCreados.join(' · ')}. Podés agregarlos desde Gestionar Equipo.',
        ),
      ),
    );
  }

  /// Procesa el inicio de sesión: el controlador delega en ServicioAcceso (HU-072).
  Future<void> _procesarLogin() async {
    await _ctrl.procesarLogin(widget.alCompletar);
  }

  /// Abre el autoservicio "olvidé mi contraseña" (HU-076 Fase 2). Pre-carga el email
  /// que el usuario ya tipeó. Si el cambio se completa, avisa que entre con la nueva.
  Future<void> _recuperarPassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => RecuperarPasswordDialog(emailInicial: _email),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Contraseña actualizada. Iniciá sesión con la nueva.'),
        ),
      );
    }
  }

  /// Elimina un usuario del equipo delegando al controlador.
  void _eliminarUsuario(Map<String, dynamic> u) {
    final index = _ctrl.usuariosEquipo.indexOf(u);
    if (index != -1) {
      _ctrl.eliminarUsuarioEquipo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Escuchar cambios en el controlador para reconstruir la pantalla cuando cambie el estado
    Provider.of<ControladorOnboarding>(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: _degradadoFondo),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _mostrarLogin ? _buildVistaLogin() : _buildVistaOnboarding(),
          ),
        ),
      ),
    );
  }

  /// Construye la vista de Login (Iniciar Sesión).
  Widget _buildVistaLogin() {
    return Center(
      key: const ValueKey('login_view'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Container(
          padding: const EdgeInsets.all(24.0),
          decoration: BoxDecoration(
            color: const Color(0x26FFFFFF), // blanco con 15% opacidad
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: const Color(0x40FFFFFF),
            ), // blanco con 25% opacidad
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // HU-127: el login es la vista RAÍZ (sin flecha "atrás"); la ida al
              // onboarding de creación de negocio vive en el CTA del pie.
              const Text(
                'Iniciar Sesión',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Acceda a su cocina sincronizando los datos desde el servidor central.',
                style: TextStyle(
                  color: Color(0xD9FFFFFF),
                  fontSize: 14,
                ), // blanco con 85% opacidad
              ),
              const SizedBox(height: 24),
              InputGlassmorphic(
                label: 'Correo Electrónico',
                hint: 'ejemplo@correo.com',
                onChange: _ctrl.actualizarLoginEmail,
                tipoTeclado: TextInputType.emailAddress,
                inputFormatters: FormatosEntrada.email(),
                icono: Icons.email_outlined,
                textInputAction: TextInputAction.next,
                onSubmitted: () => _loginPassNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              InputGlassmorphic(
                label: 'Contraseña',
                hint: '******',
                esPassword: true,
                onChange: _ctrl.actualizarLoginPassword,
                icono: Icons.lock_outline,
                focusNode: _loginPassNode,
                textInputAction: TextInputAction.done,
                onSubmitted: () {
                  if (!_loginCargando) _procesarLogin();
                },
              ),
              if (_loginError != null) ...[
                const SizedBox(height: 16),
                Text(
                  _loginError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFADBD8),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loginCargando ? null : _recuperarPassword,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xD9FFFFFF), // blanco 85%
                  ),
                  child: const Text(
                    '¿Olvidaste tu contraseña?',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _loginCargando
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : ElevatedButton(
                      onPressed: _procesarLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF2E86C1),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Iniciar Sesión →',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
              const SizedBox(height: 12),
              // HU-127: segunda opción del flujo de entrada — crear cuenta/negocio.
              TextButton(
                onPressed: _loginCargando
                    ? null
                    : () => _ctrl.conmutarMostrarLogin(),
                child: const Text(
                  '¿No tiene cuenta? Crear mi negocio',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Construye la vista principal de Onboarding paso a paso.
  Widget _buildVistaOnboarding() {
    return Column(
      key: const ValueKey('onboarding_view'),
      children: [
        _buildBarraProgreso(),
        if (_pasoActual > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: _pasoAnterior,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: Color(0x33FFFFFF), // blanco con 20% opacidad
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_back,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          child: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildPaso1Nombre(),
              _buildPaso2Tipo(),
              _buildPaso3Codigo(),
              _buildPaso4Registro(),
              _buildPaso5Plan(),
              _buildPaso6Equipo(),
            ],
          ),
        ),
      ],
    );
  }

  /// Construye la barra de progreso superior.
  Widget _buildBarraProgreso() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: List.generate(_totalPasos, (index) {
          final activo = index < _pasoActual;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              height: 4,
              decoration: BoxDecoration(
                color: activo
                    ? Colors.white
                    : const Color(0x4DFFFFFF), // 30% opacidad
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  /// PASO 1: Bienvenida e ingreso del nombre del negocio.
  Widget _buildPaso1Nombre() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'ınsuma',
              style: TextStyle(
                fontFamily: 'Georgia',
                fontStyle: FontStyle.italic,
                fontSize: 52,
                color: Colors.white,
                letterSpacing: 1,
              ),
            ),
            const Text(
              'PARA COCINAS',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 11,
                letterSpacing: 3,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Controle pedidos, insumos y costos desde un solo lugar.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xD9FFFFFF),
                fontSize: 15,
                fontWeight: FontWeight.w300,
              ),
            ),
            const SizedBox(height: 40),
            TarjetaGlass(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InputGlassmorphic(
                    label: 'Nombre de su negocio',
                    hint: 'Ej: El Fuego, La Parrilla…',
                    inputFormatters: FormatosEntrada.texto(
                      maxLongitud: SanitizadorTexto.maxLongitudNombre,
                    ),
                    onChange: (v) => _ctrl.actualizarNombreNegocio(v),
                    icono: Icons.restaurant_menu,
                    textInputAction: TextInputAction.done,
                    onSubmitted: _intentarAvanzarNombre,
                  ),
                  const SizedBox(height: 20),
                  Consumer<ControladorOnboarding>(
                    builder: (context, ctrl, _) => ElevatedButton(
                      onPressed: ctrl.nombreNegocio.trim().isEmpty
                          ? null
                          : _siguientePaso,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF2E86C1),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                      ),
                      child: const Text(
                        'Continuar →',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // HU-127: con login-first, este link VUELVE a la vista raíz (login).
            TextButton(
              onPressed: () => _ctrl.conmutarMostrarLogin(),
              child: const Text(
                '← Volver a Iniciar Sesión',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// PASO 2: Tipo de negocio.
  Widget _buildPaso2Tipo() {
    final tipos = [
      {'id': 'restaurante', 'label': 'Restaurante', 'emoji': '🍽️'},
      {'id': 'local', 'label': 'Local gastronómico', 'emoji': '🏪'},
      {'id': 'delivery', 'label': 'Delivery', 'emoji': '🛵'},
      {'id': 'otro', 'label': 'Otro', 'emoji': '✳️'},
    ];

    return _buildContenidoPaso(
      titulo: '¿Qué tipo de negocio tiene?',
      subtitulo:
          'Personalizamos la experiencia según su operación gastronómica.',
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.3,
        ),
        itemCount: tipos.length,
        itemBuilder: (context, index) {
          final t = tipos[index];
          final seleccionado = _tipoNegocio == t['id'];
          return InkWell(
            onTap: () {
              _tipoNegocio = t['id']!;
              Future.delayed(const Duration(milliseconds: 200), _siguientePaso);
            },
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: seleccionado
                    ? Colors.white
                    : const Color(0x1EFFFFFF), // 12% opacidad
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: seleccionado
                      ? Colors.white
                      : const Color(0x40FFFFFF), // 25% opacidad
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t['emoji']!, style: const TextStyle(fontSize: 24)),
                  const SizedBox(height: 8),
                  Text(
                    t['label']!,
                    style: TextStyle(
                      color: seleccionado
                          ? const Color(0xFF111111)
                          : Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// PASO 3: Código de invitación / Acceso.
  Widget _buildPaso3Codigo() {
    return _buildContenidoPaso(
      titulo: 'Código de acceso',
      subtitulo:
          'Ingrese el código de invitación que le enviamos para activar su cuenta.',
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            onPressed:
                (_codigoInvitacion.trim().isEmpty || _ctrl.validandoCodigo)
                ? null
                : _intentarValidarCodigo,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF2E86C1),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: _ctrl.validandoCodigo
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF2E86C1),
                    ),
                  )
                : const Text(
                    'Validar código →',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
          ),
          const SizedBox(height: 12),
          const Text(
            '¿No tiene un código? Escríbanos a hola@insuma.app',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0x80FFFFFF),
              fontSize: 12,
            ), // 50% opacidad
          ),
        ],
      ),
      child: Column(
        children: [
          InputGlassmorphic(
            label: 'Código de acceso',
            hint: 'Ej: K7M2-9XR4',
            inputFormatters: FormatosEntrada.alfanumerico(maxLongitud: 30),
            onChange: (v) {
              _codigoInvitacion = v;
              if (v.trim().toUpperCase() == 'INSUMA.PRUEBA' ||
                  v.trim().toUpperCase() == 'INSUMA.MAGGIE') {
                _verificarBypassOffline(v);
              }
            },
            icono: Icons.vpn_key_outlined,
            textInputAction: TextInputAction.done,
            onSubmitted: _intentarValidarCodigo,
          ),
          // Vista de error del código: inválido, ya usado, vencido o SIN CONEXIÓN.
          // Sin poder validar contra el backend no se permite crear el negocio.
          if (_ctrl.codigoError != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(
                  0x33E74C3C,
                ), // rojo translúcido sobre el degradado
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x66E74C3C)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _ctrl.codigoError!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// PASO 4: Registro / Crear cuenta administrador.
  Widget _buildPaso4Registro() {
    return _buildContenidoPaso(
      titulo: 'Crear cuenta de Administrador',
      subtitulo:
          'Con estos datos accederá como el administrador principal del sistema.',
      footer: Consumer<ControladorOnboarding>(
        builder: (context, ctrl, _) => ElevatedButton(
          onPressed:
              (ctrl.nombreAdmin.trim().isEmpty ||
                  !ValidadorDatos.validarEmail(_email) ||
                  _password.length < PoliticaPassword.longitudMinima ||
                  _password != _confirmarPassword)
              ? null
              : _siguientePaso,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF2E86C1),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: const Text(
            'Crear Cuenta →',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      child: Column(
        children: [
          InputGlassmorphic(
            label: 'Nombre completo',
            hint: 'Ej: Juan Pérez',
            inputFormatters: FormatosEntrada.texto(
              maxLongitud: SanitizadorTexto.maxLongitudNombre,
            ),
            onChange: (v) => _ctrl.actualizarNombreAdmin(v),
            icono: Icons.person_outline,
            textInputAction: TextInputAction.next,
            onSubmitted: () => _regEmailNode.requestFocus(),
          ),
          const SizedBox(height: 12),
          InputGlassmorphic(
            label: 'Email',
            hint: 'ejemplo@correo.com',
            onChange: (v) => _email = v,
            tipoTeclado: TextInputType.emailAddress,
            inputFormatters: FormatosEntrada.email(),
            icono: Icons.email_outlined,
            focusNode: _regEmailNode,
            textInputAction: TextInputAction.next,
            onSubmitted: () => _regPassNode.requestFocus(),
          ),
          const SizedBox(height: 12),
          InputGlassmorphic(
            label: 'Contraseña de administrador',
            hint: 'Mínimo 6 caracteres',
            esPassword: true,
            onChange: (v) => _password = v,
            icono: Icons.lock_outline,
            focusNode: _regPassNode,
            textInputAction: TextInputAction.next,
            onSubmitted: () => _regConfirmNode.requestFocus(),
          ),
          const SizedBox(height: 12),
          InputGlassmorphic(
            label: 'Confirmar contraseña',
            hint: 'Repita la contraseña',
            esPassword: true,
            onChange: (v) => _confirmarPassword = v,
            icono: Icons.lock_outline,
            focusNode: _regConfirmNode,
            textInputAction: TextInputAction.done,
            onSubmitted: _intentarAvanzarRegistro,
          ),
          if (_password.isNotEmpty &&
              _confirmarPassword.isNotEmpty &&
              _password != _confirmarPassword)
            const Padding(
              padding: EdgeInsets.only(top: 8.0),
              child: Text(
                'Las contraseñas no coinciden',
                style: TextStyle(
                  color: Color(0xFFF2D7D5),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// PASO 5: Plan selector.
  Widget _buildPaso5Plan() {
    return _buildContenidoPaso(
      titulo: 'Selección de plan',
      subtitulo:
          'Podrá cambiar o cancelar su suscripción en cualquier momento.',
      footer: ElevatedButton(
        onPressed: _siguientePaso,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF2E86C1),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: const Text(
          'Continuar →',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      child: Column(
        children: [
          TarjetaPlan(
            id: 'gratuito',
            titulo: 'Plan Gratuito',
            precio: '\$0',
            subtitulo:
                '14 días con todas las funciones activas. Sin tarjetas de crédito.',
            beneficios: const [
              'Pedidos ilimitados',
              'Proveedores ilimitados',
              'Auditoría de Recetas',
              'Alertas de Desviación',
            ],
            seleccionado: _planSeleccionado == 'gratuito',
            onTap: () => _planSeleccionado = 'gratuito',
          ),
          const SizedBox(height: 12),
          TarjetaPlan(
            id: 'profesional',
            titulo: 'Profesional (Próximamente)',
            precio: '\$XX',
            subtitulo:
                'Multi-sucursal en tiempo real, soporte prioritario 24/7 y OCR de facturas.',
            bloqueado: true,
            seleccionado: _planSeleccionado == 'profesional',
            onTap: () => _planSeleccionado = 'profesional',
          ),
        ],
      ),
    );
  }

  /// PASO 6: Configurar equipo (Operadores y Admins locales).
  Widget _buildPaso6Equipo() {
    final cocineros = _usuariosEquipo
        .where((u) => u['rol'] == 'cocinero')
        .toList();
    final admins = _usuariosEquipo.where((u) => u['rol'] == 'admin').toList();

    return _buildContenidoPaso(
      titulo: 'Configuración de equipo',
      subtitulo:
          'Agregue los operadores y administradores locales que utilizarán el sistema en cocina.',
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_usuariosEquipo.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8.0),
              child: Text(
                'Debe agregar al menos un usuario administrador para continuar.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFFADBD8),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          _cargando
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              : ElevatedButton(
                  onPressed: _usuariosEquipo.isEmpty
                      ? null
                      : _finalizarOnboarding,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF2E86C1),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Comenzar Operación 🚀',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
        ],
      ),
      child: Column(
        children: [
          SeccionEquipo(
            titulo: 'Operadores de cocina',
            descripcion: 'Acceso limitado: pedidos, recepciones y recetas',
            usuarios: cocineros,
            alAgregar: () => _mostrarDialogoAgregarUsuario('cocinero'),
            alEliminar: _eliminarUsuario,
          ),
          const SizedBox(height: 16),
          SeccionEquipo(
            titulo: 'Administradores locales',
            descripcion: 'Acceso completo: finanzas, equipo y catálogo',
            usuarios: admins,
            alAgregar: () => _mostrarDialogoAgregarUsuario('admin'),
            alEliminar: _eliminarUsuario,
          ),
        ],
      ),
    );
  }

  /// Diálogo/Sheet interactivo para agregar operador o admin.
  void _mostrarDialogoAgregarUsuario(String rol) {
    String nombre = '';
    String email = '';
    String password = '';
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // Valida y guarda el usuario. Reutilizada por el botón y por la tecla Enter.
            void guardar() {
              if (nombre.trim().isEmpty) {
                setModalState(
                  () => error = 'El nombre de usuario es obligatorio.',
                );
                return;
              }
              if (!ValidadorDatos.validarEmail(email)) {
                setModalState(
                  () => error = 'El correo electrónico no es válido.',
                );
                return;
              }
              // HU-088: el miembro recibe una cuenta Supabase Auth real, así que su
              // contraseña debe cumplir la MISMA política que exige la Edge Function.
              // Antes pedía 6 y el backend rechazaba con 10, ya creado el negocio.
              if (password.length < ServicioGestionEquipo.minPassword) {
                setModalState(
                  () => error =
                      'La contraseña debe tener al menos ${ServicioGestionEquipo.minPassword} caracteres.',
                );
                return;
              }

              _ctrl.agregarUsuarioEquipo(
                nombre.trim(),
                rol,
                email.trim().toLowerCase(),
                password,
              );
              Navigator.pop(context);
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                top: 16,
                left: 20,
                right: 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                  Text(
                    rol == 'cocinero'
                        ? 'Agregar Operador'
                        : 'Agregar Administrador',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    autofocus: true,
                    style: const TextStyle(color: Colors.black),
                    decoration: InputDecoration(
                      labelText: 'Nombre del usuario',
                      hintText: 'Ej: María, Carlos…',
                      hintStyle: const TextStyle(color: Colors.grey),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (v) => nombre = v,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    style: const TextStyle(color: Colors.black),
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: 'Correo electrónico',
                      hintText: 'Ej: maria@insuma.app',
                      hintStyle: const TextStyle(color: Colors.grey),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (v) => email = v,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    obscureText: true,
                    style: const TextStyle(color: Colors.black),
                    decoration: InputDecoration(
                      labelText: 'Contraseña (mínimo 6 caracteres)',
                      hintText: '******',
                      hintStyle: const TextStyle(color: Colors.grey),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (v) => password = v,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => guardar(),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: guardar,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Guardar Usuario',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Construye los contenedores de paso reutilizables.
  Widget _buildContenidoPaso({
    required String titulo,
    required String subtitulo,
    required Widget child,
    Widget? footer,
  }) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x1EFFFFFF), // blanco con 12% opacidad
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: const Color(0x33FFFFFF),
        ), // blanco con 20% opacidad
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    titulo,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitulo,
                    style: const TextStyle(
                      color: Color(0xBFFFFFFF), // blanco con 75% opacidad
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  if (_errorActual != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorActual!,
                      style: const TextStyle(
                        color: Color(0xFFFADBD8),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: child,
              ),
            ),
            if (footer != null)
              Padding(padding: const EdgeInsets.all(24.0), child: footer),
          ],
        ),
      ),
    );
  }
}
