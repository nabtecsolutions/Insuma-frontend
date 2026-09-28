import 'reconocedor_texto.dart';
import 'fabrica_reconocedor_stub.dart'
    if (dart.library.io) 'fabrica_reconocedor_io.dart'
    as impl;

export 'reconocedor_texto.dart';

/// Fábrica del motor de reconocimiento (HU-144).
///
/// Import CONDICIONAL: en web ni siquiera se compila la rama de ML Kit (el
/// paquete usa canales de plataforma); en io la rama decide en runtime si la
/// plataforma es Android/iOS (motor real) u otra (null-object).
ReconocedorTexto crearReconocedorTexto() => impl.crearReconocedorTexto();
