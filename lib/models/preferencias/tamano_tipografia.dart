/// Tamaño de tipografía elegible por el usuario (HU-054).
///
/// El [factor] multiplica el tamaño del texto vía el `textScaler` del
/// `MaterialApp`. Por eso el rango es acotado y lo fijan tests: Flutter no
/// valida el valor, así que un número grande no da error — desborda las cards y
/// los botones, y la app queda inusable sin ningún síntoma que apunte a la causa.
///
/// **No llega a todo el texto**, aunque uno lo espere: Material acota por su
/// cuenta algunos componentes. `BottomNavigationBar` limita sus etiquetas a 1.0
/// (`bottom_navigation_bar.dart`) y `AppBar` su título a 1.34 (`app_bar.dart`),
/// así que la barra de navegación principal —Pedidos, Recepciones, Proveedores,
/// Recetas— NO se agranda por más que se elija "Muy grande". Es una limitación
/// de esta entrega, no un olvido: levantarla implica rehacer el layout de esos
/// dos componentes, porque su altura está calculada para el texto sin escalar.
///
/// El orden de los valores es el orden en que se ofrecen en el panel, de menor a
/// mayor.
enum TamanoTipografia {
  pequena('Pequeña', 0.85),
  normal('Normal', 1.0),
  grande('Grande', 1.15),
  muyGrande('Muy grande', 1.3);

  const TamanoTipografia(this.etiqueta, this.factor);

  /// Texto que se muestra en el panel de configuración.
  final String etiqueta;

  /// Multiplicador aplicado al tamaño del texto.
  final double factor;

  /// El que se usa cuando no hay preferencia guardada o la guardada no se
  /// entiende. Deja la app exactamente como estaba antes de esta HU.
  static const TamanoTipografia porDefecto = TamanoTipografia.normal;

  /// Reconstruye la preferencia desde lo persistido.
  ///
  /// Nunca lanza: ante `null`, cadena vacía o un nombre desconocido devuelve
  /// [porDefecto]. El caso desconocido no es hipotético — basta que una versión
  /// posterior agregue una opción y el usuario vuelva a una anterior, con la
  /// cadena nueva ya escrita en el dispositivo.
  static TamanoTipografia parsear(String? valor) {
    for (final t in TamanoTipografia.values) {
      if (t.name == valor) return t;
    }
    return porDefecto;
  }
}
