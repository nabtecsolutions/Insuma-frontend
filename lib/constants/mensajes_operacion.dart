/// Avisos de "esta operación ya está en vuelo, no la repitas" (#176).
///
/// Viven acá y no dentro de cada controlador porque el MISMO estado —el usuario
/// tocó dos veces y la primera todavía no terminó— lo reportan pantallas
/// distintas: el pedido, la agenda de recurrentes y el selector de insumos.
/// Con el texto duplicado en cada archivo, el día que uno se reescriba la app
/// va a explicar el mismo estado de dos maneras.
class MensajesOperacion {
  const MensajesOperacion._();

  /// Segundo toque sobre "Guardar Borrador" / "Confirmar Pedido" con el
  /// guardado en curso. Es un aviso, NO un error: el pedido se está guardando
  /// bien y lo único que sobra es el segundo toque.
  static const guardadoEnCurso = 'Se está guardando, esperá un momento.';

  /// Segundo toque sobre "Agregar seleccionados" / "Insumo nuevo" mientras la
  /// carga anterior sigue corriendo.
  static const agregadoEnCurso = 'Se está agregando, esperá un momento.';
}
