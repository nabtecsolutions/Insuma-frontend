import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_superadmin.dart';
import '../theme/insuma_colors.dart';
import 'superadmin/codigos_activacion_screen.dart';
import '../utils/formatos_entrada.dart';
import '../utils/sanitizador_texto.dart';

/// Vista DEDICADA del SuperAdmin global (HU-037).
///
/// Es el "home" del usuario de control: lista todos los negocios de la nube y
/// permite entrar a gestionar cualquiera. No es el dashboard de cocina: tiene su
/// propia identidad visual (panel de control). Al entrar a un negocio, se descargan
/// sus datos y se reutilizan las pantallas operativas existentes.
class PantallaSuperAdmin extends StatefulWidget {
  const PantallaSuperAdmin({super.key});

  @override
  State<PantallaSuperAdmin> createState() => _PantallaSuperAdminState();
}

class _PantallaSuperAdminState extends State<PantallaSuperAdmin> {
  static const Color _fondo = Color(0xFF0F172A); // slate 900
  static const Color _panel = Color(0xFF1E293B); // slate 800

  ServicioSuperAdmin? _servicio;
  List<NegocioSuperAdmin> _negocios = [];
  bool _cargando = true;
  String? _error;
  String? _abriendoId; // negocio que se está abriendo (overlay)

  @override
  void initState() {
    super.initState();
    _servicio = context.read<ServicioSuperAdmin?>();
    _cargarNegocios();
  }

  Future<void> _cargarNegocios() async {
    if (_servicio == null) {
      setState(() {
        _cargando = false;
        _error = 'Supabase no está configurado en este dispositivo.';
      });
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final lista = await _servicio!.listarNegocios();
      if (!mounted) return;
      setState(() {
        _negocios = lista;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = 'No se pudieron cargar los negocios: $e';
      });
    }
  }

  Future<void> _entrarANegocio(NegocioSuperAdmin negocio) async {
    setState(() => _abriendoId = negocio.id);
    try {
      // #246: el pull corre en SEGUNDO PLANO y se entra de inmediato — el
      // patrón de HU-134 en el login, que a este camino nunca se le aplicó.
      // Esperar acá el pull completo (19 tablas paginadas, sin timeout) era
      // el "tarda varios minutos en ingresar" del reporte del cliente. Lo ya
      // local se ve al toque; las pantallas se actualizan solas vía watch()
      // cuando el pull deposita novedades (HU-089/HU-128), y la guarda del
      // primer pull (HU-090) sigue bloqueando los movimientos financieros
      // hasta hidratar.
      unawaited(_descargarEnSegundoPlano(negocio));
      // Al setear el negocio activo, el ruteo reactivo (PantallaInicial) muestra el dashboard.
      await context.read<ServicioSesion>().entrarANegocio(
        negocioId: negocio.id,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _abriendoId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo abrir "${negocio.nombre}": $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// El pull de fondo NO puede depender del `context` de esta pantalla: para
  /// cuando termina (o falla), el superadmin ya está adentro del negocio y
  /// este State puede no existir más. Un fallo acá no es fatal — se navega
  /// con lo local y el próximo pull (arranque/reconexión) reintenta — pero
  /// deja rastro en consola para poder diagnosticarlo.
  Future<void> _descargarEnSegundoPlano(NegocioSuperAdmin negocio) async {
    try {
      await _servicio!.descargarNegocio(negocio.id);
    } catch (e) {
      debugPrint('[SUPERADMIN] Pull de fondo de "${negocio.nombre}" falló: $e');
    }
  }

  Future<void> _cerrarSesion() async {
    final sesion = context.read<ServicioSesion>();
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: const Text('¿Salir de la sesión de SuperAdmin?'),
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
    if (confirmar != true) return;
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      /* sin conexión: igual cerramos la sesión local */
    }
    await sesion.cerrarSesion();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _fondo,
      appBar: AppBar(
        backgroundColor: _fondo,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            const Icon(
              Icons.shield_outlined,
              color: InsumaColors.primaryBlue,
              size: 22,
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Panel SuperAdmin',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Control global de negocios',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // HU-075: emitir/gestionar los códigos que habilitan crear un negocio.
          IconButton(
            icon: const Icon(Icons.vpn_key_outlined, color: Colors.white70),
            tooltip: 'Códigos de activación',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const PantallaCodigosActivacion(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Actualizar',
            onPressed: _cargando ? null : _cargarNegocios,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white70),
            tooltip: 'Cerrar sesión',
            onPressed: _cerrarSesion,
          ),
        ],
      ),
      body: Stack(
        children: [
          _construirCuerpo(),
          if (_abriendoId != null) _overlayAbriendo(),
        ],
      ),
      floatingActionButton: _servicio == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _mostrarFormularioNegocio(),
              backgroundColor: InsumaColors.primaryBlue,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_business),
              label: const Text('Nuevo negocio'),
            ),
    );
  }

  Widget _construirCuerpo() {
    if (_cargando) {
      return const Center(
        child: CircularProgressIndicator(color: InsumaColors.primaryBlue),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: Colors.white38, size: 48),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _cargarNegocios,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: InsumaColors.primaryBlue,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_negocios.isEmpty) {
      return const Center(
        child: Text(
          'Todavía no hay negocios creados.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _cargarNegocios,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _negocios.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '${_negocios.length} ${_negocios.length == 1 ? 'negocio' : 'negocios'}',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            );
          }
          final negocio = _negocios[index - 1];
          return _tarjetaNegocio(negocio);
        },
      ),
    );
  }

  Widget _tarjetaNegocio(NegocioSuperAdmin negocio) {
    final subtitulo = [
      if (negocio.tipo.isNotEmpty) negocio.tipo,
      if (negocio.email != null && negocio.email!.isNotEmpty) negocio.email!,
    ].join(' · ');

    return Card(
      color: _panel,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: InsumaColors.primaryBlue.withValues(alpha: 0.18),
          child: const Icon(
            Icons.storefront,
            color: InsumaColors.primaryBlue,
            size: 20,
          ),
        ),
        title: Text(
          negocio.nombre,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: subtitulo.isEmpty
            ? null
            : Text(
                subtitulo,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(
                Icons.edit_outlined,
                color: Colors.white54,
                size: 20,
              ),
              tooltip: 'Editar negocio',
              onPressed: () => _mostrarFormularioNegocio(negocio: negocio),
            ),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
        onTap: () => _entrarANegocio(negocio),
      ),
    );
  }

  /// Formulario (bottom sheet) para crear o editar un negocio. Operación de escritura
  /// del SuperAdmin: escribe directo en Supabase vía ServicioSuperAdmin (HU-042).
  void _mostrarFormularioNegocio({NegocioSuperAdmin? negocio}) {
    final esEdicion = negocio != null;
    final nombreCtrl = TextEditingController(text: negocio?.nombre ?? '');
    final paisCtrl = TextEditingController(text: negocio?.pais ?? 'Argentina');
    final emailCtrl = TextEditingController(text: negocio?.email ?? '');
    const tipos = ['restaurante', 'local', 'delivery', 'otro'];
    var tipo = (negocio != null && negocio.tipo.isNotEmpty)
        ? negocio.tipo
        : 'restaurante';
    String? error;
    var guardando = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            Future<void> guardar() async {
              final messenger = ScaffoldMessenger.of(context);
              if (nombreCtrl.text.trim().isEmpty) {
                setSheet(() => error = 'El nombre del negocio es obligatorio.');
                return;
              }
              setSheet(() {
                error = null;
                guardando = true;
              });
              try {
                // HU-137: se normaliza lo que se persiste, no solo lo que se valida.
                final pais = SanitizadorTexto.tieneContenido(paisCtrl.text)
                    ? SanitizadorTexto.limpiar(paisCtrl.text)
                    : 'Argentina';
                final nombreNegocio = SanitizadorTexto.limpiar(
                  nombreCtrl.text,
                  maxLongitud: SanitizadorTexto.maxLongitudNombre,
                );
                final emailNegocio = SanitizadorTexto.limpiar(emailCtrl.text);
                if (esEdicion) {
                  await _servicio!.editarNegocio(
                    id: negocio.id,
                    nombre: nombreNegocio,
                    tipo: tipo,
                    pais: pais,
                    email: emailNegocio,
                  );
                } else {
                  await _servicio!.crearNegocio(
                    nombre: nombreNegocio,
                    tipo: tipo,
                    pais: pais,
                    email: emailNegocio,
                  );
                }
                if (!sheetContext.mounted) return;
                Navigator.pop(sheetContext);
                await _cargarNegocios();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      esEdicion ? 'Negocio actualizado.' : 'Negocio creado.',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              } catch (e) {
                setSheet(() {
                  guardando = false;
                  error = 'No se pudo guardar: $e';
                });
              }
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
                    esEdicion ? 'Editar negocio' : 'Nuevo negocio',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nombreCtrl,
                    autofocus: true,
                    inputFormatters: FormatosEntrada.texto(
                      maxLongitud: SanitizadorTexto.maxLongitudNombre,
                    ),
                    style: const TextStyle(color: Colors.black),
                    decoration: InputDecoration(
                      labelText: 'Nombre del negocio',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Tipo',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[700],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: tipos.map((t) {
                      return ChoiceChip(
                        label: Text('${t[0].toUpperCase()}${t.substring(1)}'),
                        selected: tipo == t,
                        onSelected: (_) => setSheet(() => tipo = t),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: paisCtrl,
                    inputFormatters: FormatosEntrada.texto(maxLongitud: 60),
                    style: const TextStyle(color: Colors.black),
                    decoration: InputDecoration(
                      labelText: 'País',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    inputFormatters: FormatosEntrada.email(),
                    style: const TextStyle(color: Colors.black),
                    decoration: InputDecoration(
                      labelText: 'Email (opcional)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
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
                    onPressed: guardando ? null : guardar,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: InsumaColors.primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: guardando
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            esEdicion ? 'Guardar cambios' : 'Crear negocio',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      nombreCtrl.dispose();
      paisCtrl.dispose();
      emailCtrl.dispose();
    });
  }

  Widget _overlayAbriendo() {
    final negocio = _negocios.firstWhere(
      (n) => n.id == _abriendoId,
      orElse: () => NegocioSuperAdmin(id: '', nombre: '', tipo: ''),
    );
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: InsumaColors.primaryBlue),
            const SizedBox(height: 16),
            Text(
              'Abriendo "${negocio.nombre}"…',
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 4),
            const Text(
              'Descargando datos del negocio',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
