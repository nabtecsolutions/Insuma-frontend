import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../data/repositorios/repositorio_codigos_activacion.dart';
import '../../services/servicio_activacion.dart';
import '../../utils/formatos_entrada.dart';
import '../../utils/sanitizador_texto.dart';

/// Panel de códigos de activación del SuperAdmin (HU-075).
///
/// El SuperAdmin emite un código y se lo entrega al dueño de un negocio nuevo
/// (junto con el link a la tienda). Sin un código válido nadie puede crear una
/// cuenta. Cada código es de **un solo uso** y **vence a los 7 días**.
class PantallaCodigosActivacion extends StatefulWidget {
  const PantallaCodigosActivacion({super.key});

  @override
  State<PantallaCodigosActivacion> createState() =>
      _PantallaCodigosActivacionState();
}

class _PantallaCodigosActivacionState extends State<PantallaCodigosActivacion> {
  static const Color _fondo = Color(0xFF0F172A); // slate 900
  static const Color _panel = Color(0xFF1E293B); // slate 800

  ServicioActivacion? _servicio;
  List<CodigoActivacion> _codigos = [];
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _servicio = context.read<ServicioActivacion?>();
    _cargar();
  }

  Future<void> _cargar() async {
    final servicio = _servicio;
    if (servicio == null) {
      setState(() {
        _cargando = false;
        _error = 'No hay backend configurado: no se pueden gestionar códigos.';
      });
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final codigos = await servicio.listar();
      if (!mounted) return;
      setState(() {
        _codigos = codigos;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = 'No se pudieron cargar los códigos: $e';
      });
    }
  }

  /// Emite un código nuevo y lo muestra en un diálogo para copiarlo/dictarlo.
  Future<void> _emitir() async {
    final servicio = _servicio;
    if (servicio == null) return;

    final nota = await _pedirNota();
    if (nota == null || !mounted) return; // cancelado

    final messenger = ScaffoldMessenger.of(context);
    try {
      final codigo = await servicio.emitir(nota: nota);
      if (!mounted) return;
      await _mostrarCodigoEmitido(codigo);
      await _cargar();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('No se pudo emitir el código: $e')),
      );
    }
  }

  Future<String?> _pedirNota() {
    var nota = '';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        title: const Text(
          'Emitir código',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Para qué cliente es. Sirve para identificarlo después.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Nota (opcional)',
                hintText: 'Ej: Restaurante Don Pepe — tutoría',
                labelStyle: TextStyle(color: Colors.white70),
                hintStyle: TextStyle(color: Colors.white38),
              ),
              inputFormatters: FormatosEntrada.texto(
                maxLongitud: SanitizadorTexto.maxLongitudNota,
              ),
              onChanged: (v) => nota = v,
            ),
            const SizedBox(height: 12),
            const Text(
              'El código será de un solo uso y vencerá en 7 días.',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nota),
            child: const Text('Emitir'),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarCodigoEmitido(String codigo) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        title: const Text(
          'Código emitido',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Entregáselo al dueño del negocio junto con el link a la tienda.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 16),
            SelectableText(
              codigo,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Un solo uso · vence en 7 días',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: codigo));
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.copy, size: 16, color: Colors.white70),
            label: const Text(
              'Copiar y cerrar',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _revocar(CodigoActivacion codigo) async {
    final servicio = _servicio;
    if (servicio == null) return;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        title: const Text(
          'Revocar código',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          'El código ${servicio.formatear(codigo.codigo)} dejará de servir para crear un negocio.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revocar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await servicio.revocar(codigo.id);
      await _cargar();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('No se pudo revocar: $e')));
    }
  }

  /// Etiqueta legible del estado, contemplando el vencimiento (derivado).
  ({String texto, Color color}) _estadoDe(CodigoActivacion c) {
    if (c.estado == 'consumido') {
      return (texto: 'Usado', color: Colors.blueGrey);
    }
    if (c.estado == 'revocado') {
      return (texto: 'Revocado', color: Colors.redAccent);
    }
    if (c.vencido) return (texto: 'Vencido', color: Colors.orangeAccent);
    return (texto: 'Disponible', color: Colors.greenAccent);
  }

  @override
  Widget build(BuildContext context) {
    final servicio = _servicio;
    return Scaffold(
      backgroundColor: _fondo,
      appBar: AppBar(
        backgroundColor: _fondo,
        foregroundColor: Colors.white,
        title: const Text('Códigos de activación'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recargar',
            onPressed: _cargar,
          ),
        ],
      ),
      floatingActionButton: servicio == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _emitir,
              icon: const Icon(Icons.add),
              label: const Text('Emitir código'),
            ),
      body: _buildCuerpo(),
    );
  }

  Widget _buildCuerpo() {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (_codigos.isEmpty) {
      return const Center(
        child: Text(
          'Todavía no emitiste ningún código.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    final servicio = _servicio!;
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _codigos.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final c = _codigos[i];
        final estado = _estadoDe(c);
        return Container(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(14),
          ),
          child: ListTile(
            title: Text(
              servicio.formatear(c.codigo),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            subtitle: Text(
              [
                estado.texto,
                if (c.nota != null && c.nota!.isNotEmpty) c.nota!,
              ].join(' · '),
              style: TextStyle(color: estado.color, fontSize: 12),
            ),
            trailing: c.disponible
                ? IconButton(
                    icon: const Icon(Icons.block, color: Colors.redAccent),
                    tooltip: 'Revocar',
                    onPressed: () => _revocar(c),
                  )
                : null,
          ),
        );
      },
    );
  }
}
