import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../models/preferencias/tamano_tipografia.dart';
import '../../services/servicio_configuracion_negocio.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_preferencias_usuario.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../widgets/campo_numerico.dart';

/// Panel de configuración personal (HU-054).
///
/// **Sin [GuardiaPermiso] a propósito**, a diferencia del resto de pantallas que
/// cuelgan del menú: acá nadie administra el negocio, cada uno ajusta cómo ve su
/// propia app. Pedirle permiso de admin al cocinero para agrandar la letra sería
/// negarle una función de accesibilidad por su rol.
///
/// Las preferencias son del DISPOSITIVO (ver [ServicioPreferenciasUsuario]), y
/// eso se le dice al usuario en pantalla: si no, quien las cambia en el celular
/// va a esperar encontrarlas en la tablet de la cocina.
class PantallaConfiguracion extends StatelessWidget {
  const PantallaConfiguracion({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<ServicioPreferenciasUsuario>();
    final sesion = context.watch<ServicioSesion>();

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        title: const Text('Configuración'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _Encabezado(),
          const _TituloSeccion('Apariencia'),
          const _MuestraDeTexto(),
          RadioGroup<TamanoTipografia>(
            groupValue: prefs.tipografia,
            onChanged: (elegido) {
              if (elegido == null) return;
              // Si la escritura falla, el servicio NO aplica el cambio; hay que
              // decirlo. Sin esto el usuario ve que su elección "no hizo nada" y
              // no tiene forma de distinguirlo de un toque que no registró.
              prefs.cambiarTipografia(elegido).then((guardado) {
                if (guardado || !context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('No se pudo guardar el tamaño de letra.'),
                  ),
                );
              });
            },
            child: Column(
              children: [
                for (final tamano in TamanoTipografia.values)
                  RadioListTile<TamanoTipografia>(
                    value: tamano,
                    activeColor: InsumaColors.primaryBlue,
                    title: Text(tamano.etiqueta),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Text(
              'El tamaño de letra se guarda en este dispositivo y se suma al que '
              'tengas configurado en el sistema.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          // HU-152: parámetro del NEGOCIO, no del dispositivo. Se muestra sólo a
          // quien puede ver finanzas — mismo criterio con el que el listado de
          // recetas esconde los costos al cocinero.
          //
          // El permiso se evalúa ACÁ y no dentro de la sección: así el árbol de
          // un cocinero ni siquiera construye el widget, y por lo tanto no pide
          // la configuración del negocio que igual no tendría por qué leer.
          if (Permisos.puede(sesion.usuarioRol, Permiso.verFinanzas))
            const _SeccionNegocio(),
        ],
      ),
    );
  }
}

/// Quién está usando la app. Da contexto a un panel que, si no, es una lista de
/// opciones sueltas; y es donde la HU-194 va a colgar la foto de perfil.
class _Encabezado extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final sesion = context.watch<ServicioSesion>();
    final nombre = sesion.usuarioNombre;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: InsumaColors.primaryBlue,
        foregroundColor: Colors.white,
        child: const Icon(Icons.person),
      ),
      title: Text(
        nombre.isEmpty ? 'Mi cuenta' : nombre,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(Permisos.etiquetaDeRol(sesion.usuarioRol)),
    );
  }
}

class _TituloSeccion extends StatelessWidget {
  const _TituloSeccion(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
    child: Text(
      texto,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.grey,
      ),
    ),
  );
}

/// Muestra en vivo del tamaño elegido.
///
/// Existe porque los nombres no alcanzan: "Grande" no dice cuánto, y elegir a
/// ciegas obliga a salir del panel, mirar y volver.
///
/// **No fija `textScaler`.** Un `textScaler` explícito en un `Text` REEMPLAZA
/// al del `MediaQuery` en vez de combinarse (`Text.build` resuelve
/// `this.textScaler ?? MediaQuery.textScalerOf(context)`), así que poner acá
/// `TextScaler.linear(factor)` descartaba el ajuste del sistema: en un teléfono
/// con la letra al 1,4x la muestra se dibujaba MÁS CHICA que las etiquetas de
/// abajo, y el usuario elegía mirando un tamaño que la app no iba a usar.
///
/// Heredando el escalador ambiente —que `EscaladorDeTexto` ya compuso— la
/// muestra es literalmente el mismo pipeline que el resto de la app. Se
/// actualiza sola al elegir otra opción porque `InsumaApp` observa el servicio.
class _MuestraDeTexto extends StatelessWidget {
  const _MuestraDeTexto();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('muestra-tipografia'),
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.grey.shade300),
    ),
    child: const Text(
      'Así se va a ver el texto de la app.',
      style: TextStyle(fontSize: 15, color: Colors.black87),
    ),
  );
}

/// Parámetros del NEGOCIO dentro del panel de configuración (HU-152).
///
/// A diferencia de "Apariencia" —que es del dispositivo y la ve cualquiera—, esto
/// es un dato del negocio que impacta en el costo de todas las recetas, así que
/// **se muestra sólo con [Permiso.verFinanzas]**.
///
/// El guard va acá y NO en [PantallaConfiguracion]: poner un `GuardiaPermiso` a
/// nivel pantalla le negaría al cocinero el ajuste de tamaño de letra, que es una
/// función de accesibilidad y el motivo explícito por el que la HU-054 dejó esta
/// pantalla sin guard. Se esconde la sección, no el panel.
class _SeccionNegocio extends StatefulWidget {
  const _SeccionNegocio();

  @override
  State<_SeccionNegocio> createState() => _SeccionNegocioState();
}

class _SeccionNegocioState extends State<_SeccionNegocio> {
  ConfiguracionNegocioData? _config;
  double? _costoHora;
  bool _guardando = false;

  /// La carga TERMINO, con o sin exito. Sin esta bandera, `_config == null`
  /// significaba a la vez "todavia cargando" y "no se pudo cargar", y una sesion
  /// sin negocio o un error de lectura dejaban un spinner girando para siempre.
  bool _cargaTerminada = false;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final sesion = context.read<ServicioSesion>();
    if (sesion.negocioId.isEmpty) {
      setState(() {
        _cargaTerminada = true;
        _errorCarga = 'No hay un negocio activo en esta sesion.';
      });
      return;
    }
    try {
      // `leer` y no `obtener`: abrir la pantalla no puede dar de alta la fila
      // (#203). Puede volver null — el negocio todavía no configuró nada — y en
      // ese caso el campo se muestra vacío igual.
      final config = await context.read<ServicioConfiguracionNegocio>().leer(
        sesion.negocioId,
      );
      if (!mounted) return;
      setState(() {
        _config = config;
        _costoHora = config?.costoHoraEmpleado;
        _cargaTerminada = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cargaTerminada = true;
        _errorCarga = 'No se pudo leer la configuracion del negocio.';
      });
    }
  }

  Future<void> _guardar() async {
    setState(() => _guardando = true);

    // Si el escribir falla hay que decirlo: sin aviso, el usuario ve que su
    // cambio "no hizo nada" y no puede distinguirlo de un toque que no registró.
    // (Misma lección que el selector de tipografía de HU-054.)
    try {
      // Se REASIGNA `_config` con la fila devuelta. Sin esto, un segundo
      // guardado usaria la version vieja: `guardar` escribe `version + 1` (el
      // mismo numero otra vez) y encola el UPDATE con el `versionBase` anterior,
      // asi que el push no matchea ninguna fila, se marca como conflicto y el
      // valor nuevo NUNCA llega al servidor — mientras la pantalla dice
      // "guardado". La guarda de concurrencia optimista es de HU-028.
      //
      // Y se RELEE la fila antes de escribir (#203). El `config` que tiene la
      // pantalla es del momento en que se abrió: si mientras tanto entró un pull
      // con cambios de otro dispositivo, guardar sobre esa copia vieja los
      // pisaba en silencio. Se relee y se aplica ENCIMA sólo el campo que el
      // usuario editó acá, así lo que cambió en otro lado sobrevive.
      final servicio = context.read<ServicioConfiguracionNegocio>();
      final sesion = context.read<ServicioSesion>();
      // Acá SÍ se crea si no existe: guardar es un acto deliberado del usuario.
      final vigente = await servicio.obtener(sesion.negocioId);

      // Si el costo por hora cambió en otro dispositivo desde que se abrió esta
      // pantalla, NO se pisa.
      //
      // Releer sin este chequeo era peor que no releer: antes, guardar sobre la
      // fila vieja mandaba un `versionBase` desactualizado y la guarda de
      // concurrencia de HU-028 marcaba conflicto, así que el valor remoto
      // sobrevivía. Al releer, la versión pasa a estar al día y el push entra
      // limpio — o sea que el campo que el usuario ni tocó volvía al valor de
      // esta pantalla, en silencio y sin quedar registrado como conflicto.
      if (_config != null &&
          vigente.costoHoraEmpleado != _config!.costoHoraEmpleado) {
        if (!mounted) return;
        setState(() {
          _config = vigente;
          _costoHora = vigente.costoHoraEmpleado;
          _guardando = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'El costo por hora cambió desde otro dispositivo. '
              'Revisá el valor y volvé a guardar.',
            ),
          ),
        );
        return;
      }

      final actualizada = await servicio.guardar(
        vigente.copyWith(costoHoraEmpleado: Value(_costoHora)),
      );
      if (!mounted) return;
      setState(() {
        _config = actualizada;
        _guardando = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Costo por hora guardado.')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _guardando = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo guardar el costo por hora.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_cargaTerminada) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // `_config == null` ya NO es un error: desde #203 abrir la pantalla no crea
    // la fila, así que null es el estado normal de un negocio que todavía no
    // configuró nada — el campo se muestra vacío y la fila nace al guardar. El
    // único caso de error es el que dejó un mensaje en `_errorCarga`.
    if (_errorCarga != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Text(
          _errorCarga!,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _TituloSeccion('Negocio'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: CampoNumerico(
            key: const Key('costo-hora-empleado'),
            etiqueta: 'Costo de la hora de trabajo',
            valorInicial: _costoHora,
            // Opcional: si nunca se cargó, la app avisa en vez de inventar un
            // número. Un campo obligatorio acá trabaría el panel entero por un
            // dato que el negocio puede no tener todavía.
            obligatorio: false,
            // 0 tampoco es inválido: el dominio lo lee como "sin configurar"
            // (ningún negocio paga $0 la hora). Con `permitirCero: false` el
            // campo pintaba "Debe ser mayor a 0" mientras el guardado lo
            // aceptaba igual — no vive dentro de un Form, así que el validador
            // sólo servía para contradecir a la propia pantalla.
            permitirCero: true,
            prefijo: '\$ ',
            ayuda: 'Se usa para calcular la mano de obra de cada receta',
            alCambiar: (v) => setState(() => _costoHora = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: FilledButton(
            key: const Key('guardar-costo-hora'),
            onPressed: _guardando ? null : _guardar,
            child: Text(_guardando ? 'Guardando…' : 'Guardar'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Text(
            'Mientras no cargues este valor, la mano de obra de las recetas vale '
            '0 y la app te lo avisa: un cero sin explicación se lee como "no '
            'cuesta nada".',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    );
  }
}
