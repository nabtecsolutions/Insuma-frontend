# INSUMA frontend — guía para trabajar la interfaz

> Este repo es una copia de la app INSUMA para **probar variantes de interfaz**.
> El objetivo es cambiar cómo se ve y cómo se navega, no cómo funcionan los datos.
> Los diseños que funcionen se van a portar después a mano al repo principal:
> cuanto más acotado el cambio a pantallas y tema, más fácil ese traspaso.

## Qué se puede tocar libremente

```
lib/screens/<área>/          ← pantallas. Áreas: onboarding, dashboard, insumos,
                               proveedores, recibir, pagos, recurrentes, recetas,
                               configuracion, superadmin.
lib/screens/<área>/widgets/  ← widgets propios de esa área.
lib/screens/widgets/         ← widgets compartidos por más de un área.
lib/screens/*_tab.dart, *_screen.dart  ← pantallas y pestañas de primer nivel.
lib/theme/insuma_colors.dart ← paleta de colores. Preferir cambiar colores acá
                               antes que escribir `Color(0x...)` en cada pantalla.
```

## Qué NO tocar (salvo que se sepa exactamente por qué)

```
lib/services/        ← lógica de negocio (costos, recepciones, pagos, permisos).
lib/data/            ← repositorios y acceso a datos.
lib/database/        ← esquema de la base local (Drift). `database.g.dart` es generado.
lib/utils/           ← cálculos puros (costos, validaciones).
lib/main.dart        ← arranque, inyección de dependencias y sincronización.
```

Un cambio ahí puede romper la sincronización con Supabase o guardar datos mal, y
no se ve en pantalla hasta mucho después. Si una idea de interfaz necesita un dato
que hoy no existe, anotarlo como pedido al equipo en vez de agregarlo acá.

## Cómo está armada una pantalla

- **Estado:** `provider` + `ChangeNotifier`. No agregar Riverpod, BLoC, GetX ni otra
  librería de estado.
- **Controllers** (`lib/controllers/`): exponen los datos y las acciones que usa la
  pantalla. No tienen lógica de negocio ni `BuildContext`. Una pantalla nueva
  reutiliza el controller existente de su área.
- **Leer un controller desde un widget:**
  - `context.watch<X>()` dentro de `build`, para redibujar cuando cambia.
  - `context.read<X>()` en botones, callbacks e `initState`, para llamar acciones.
  - `context.select<X, T>(...)` si la pantalla sólo depende de un campo.
  - No usar `Provider.of` ni llamar `notifyListeners()` desde `build`.
- **Estado que vive sólo en un widget** (un campo abierto/cerrado, una pestaña
  seleccionada): `setState` en un `StatefulWidget`, no un controller.

## Correr y revisar

```bash
flutter run -d chrome    # necesita assets/.env, ver README.md
flutter analyze          # tiene que dar 0 issues antes de subir cambios
dart format lib          # formato estándar
```

## Estilo

- Nombres de clases, variables y textos de la UI en español, como el resto del código.
- Extraer a un widget propio lo que se repite en más de una pantalla, en vez de copiarlo.
