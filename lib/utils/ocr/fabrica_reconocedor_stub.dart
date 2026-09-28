import 'reconocedor_texto.dart';

/// Rama SIN dart:io (web): no hay motor de reconocimiento.
ReconocedorTexto crearReconocedorTexto() =>
    const ReconocedorTextoNoDisponible();
