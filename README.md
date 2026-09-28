# INSUMA — frontend

Copia de la app INSUMA (Flutter) para explorar variantes de interfaz.
Gestión de costos gastronómicos offline-first con sincronización a Supabase.

## Requisitos

- Flutter 3.44 o superior (Dart `^3.12.1`). Verificar con `flutter --version`.
- Chrome, para correrla en web.

## Arrancar

```bash
flutter pub get
cp assets/.env.example assets/.env   # y completar SUPABASE_URL / SUPABASE_ANON_KEY
flutter run -d chrome
```

Los valores de Supabase y un usuario para entrar los pasa el equipo de desarrollo.
Todo lo que hagas en la app (crear insumos, pedidos, pagos) se guarda de verdad en
esa base: usá el entorno que te indiquen, no uno con datos reales.

En Windows, si `git clone` falla con `Filename too long`, habilitá rutas largas:
`git config --global core.longpaths true`.

## Dónde está cada cosa

Ver [`CLAUDE.md`](CLAUDE.md): qué carpetas son de interfaz y cuáles conviene no tocar.
