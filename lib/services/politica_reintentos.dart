/// Política de reintentos del Outbox de sincronización (C-02).
///
/// Vive aparte del servicio a propósito: la regla —cuándo un fallo gasta un
/// intento y cuánto conviene esperar— es lógica de negocio, y dentro del bucle
/// de drenaje no se puede probar sin una sesión de Supabase viva. Acá es una
/// función pura y falsable.
///
/// ## La regla, y por qué
///
/// El contador de intentos existe para frenar una mutación que el backend
/// rechaza una y otra vez. Su premisa es *"si falló, la mutación está mal"* —
/// y esa premisa **sólo vale para un rechazo definitivo**: un fallo de red, o
/// un 503 del gateway, no dicen absolutamente nada sobre si la mutación es
/// válida.
///
/// Contarlos igual rompía el caso de uso central de una app offline-first: cada
/// mutación local dispara un drenaje, así que ocho ediciones seguidas sin
/// conexión quemaban los ocho intentos de la primera y la mandaban a
/// dead-letter **antes de que hubiera existido una sola chance de subirla**. El
/// dato quedaba sólo en el teléfono, sin aviso.
///
/// Es el mismo criterio que el equipo ya aplicaba cuando no hay sesión (ver
/// `_puedeSincronizar`): no gastar reintentos por algo ajeno a la mutación.
library;

import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Qué hacer con un ítem de la cola que acaba de fallar.
class DecisionReintento {
  /// ¿Se incrementa el contador? Sólo ante un rechazo definitivo.
  final bool gastaIntento;

  /// Cuánto esperar antes de volver a intentar este ítem.
  final Duration espera;

  const DecisionReintento({required this.gastaIntento, required this.espera});
}

/// Decide qué hacer tras un fallo de push. Pura: no toca la base ni el reloj.
class PoliticaReintentos {
  /// Espera cuando el fallo NO fue un rechazo definitivo.
  ///
  /// Corta, para que el ítem vuelva enseguida cuando la red aparezca; y no
  /// cero, para no dejar un bucle caliente de timeouts mientras sigue sin
  /// haberla.
  static const Duration esperaSinRed = Duration(seconds: 30);

  /// Tope del backoff tras un rechazo definitivo.
  static const Duration esperaMaxima = Duration(minutes: 5);

  /// Primer escalón del backoff exponencial.
  static const Duration esperaBase = Duration(seconds: 10);

  /// ¿[error] es un rechazo DEFINITIVO —el backend miró esta mutación y dijo
  /// que no— o algo que no habla de la mutación?
  ///
  /// **Se clasifica por clase de status HTTP, no por tipo de excepción.** El
  /// primer intento fue `e is PostgrestException`, y era demasiado grueso:
  /// postgrest convierte en `PostgrestException` **toda** respuesta no-2xx,
  /// incluidas las del gateway (un 502/503/504 de Cloudflare o un proyecto
  /// Supabase pausado). Con esa regla, quince minutos de corte transitorio
  /// agotaban los ocho intentos de todo lo encolado y lo mandaban a
  /// dead-letter en silencio — que es exactamente el fallo que C-02 vino a
  /// eliminar, sólo que más lento.
  ///
  /// Un 503 dice tan poco sobre la validez de la mutación como un socket
  /// cortado. Un 42501 (RLS) o un 23505 (unique violation), en cambio, son el
  /// backend rechazando *esta* mutación, y van a seguir rechazándola.
  static bool esRechazoDefinitivo(Object error) {
    // Nunca llegamos: sin red, DNS, timeout, socket cortado, o un `AuthException`
    // del refresco de token. Nada de eso habla de la mutación.
    if (error is! PostgrestException) return false;

    // `code` es heterogéneo: SQLSTATE de Postgres (`42501`, `23505`, `PGRST204`)
    // cuando el cuerpo vino en JSON, y el status HTTP como string (`'503'`)
    // cuando no se pudo parsear —el caso del gateway, que responde HTML—.
    // Se exige largo 3 para no confundirlos: los SQLSTATE tienen cinco
    // caracteres, así que un `'503'` sólo puede ser un status.
    final codigo = error.code;
    if (codigo != null && codigo.length == 3) {
      final http = int.tryParse(codigo);
      // 5xx: el servidor falló, no la mutación. 429: pediste demasiado rápido,
      // que es literalmente "reintentá más tarde".
      if (http != null && (http == 429 || (http >= 500 && http < 600))) {
        return false;
      }
    }

    // Cuando el cuerpo SÍ vino en JSON, `code` es el SQLSTATE y la rama de
    // arriba no se activa —los SQLSTATE tienen cinco caracteres—. Y PostgREST
    // manda SQLSTATE en la mayoría de sus 5xx, así que sin esta segunda tabla
    // el pool de conexiones saturado veinte minutos (`53300`) mandaba toda la
    // cola a dead-letter: exactamente el fallo que C-02 vino a eliminar.
    //
    // Se clasifica por CLASE de SQLSTATE, que es como Postgres los agrupa:
    return switch (codigo) {
      // 08 = connection exception. 53 = insufficient resources (`53300`
      // too_many_connections es EL fallo estrella de Supabase). 57 = operator
      // intervention (`57014` statement timeout).
      final c? when c.startsWith('08') || c.startsWith('53') => false,
      final c? when c.startsWith('57') => false,
      // Fallos de concurrencia: el reintento es literalmente el remedio que
      // prescribe Postgres.
      '40001' || '40P01' => false,
      // JWT vencido o inválido: es la sesión, no la mutación. El drenaje se
      // frena solo por `_puedeSincronizar` en cuanto gotrue borra la sesión.
      'PGRST301' || 'PGRST303' => false,
      // FK violation. En el Outbox casi siempre significa "el padre todavía no
      // subió", no "esta fila está mal": las dos van en la misma cola FIFO y
      // basta con que el padre haya quedado esperando su backoff. Contarlo
      // mataba al hijo mientras el padre seguía intentando, y perdía el dato
      // en silencio.
      //
      // El precio es que una fila realmente huérfana reintenta para siempre.
      // Es el mismo leak que ya se acepta para los fallos de red, y es
      // preferible a perder trabajo del usuario sin avisar.
      '23503' => false,
      _ => true,
    };
  }

  /// [esRechazoDefinitivo] sale de [PoliticaReintentos.esRechazoDefinitivo].
  ///
  /// [intentosPrevios] es el contador ANTES de este fallo.
  ///
  /// [azar] se inyecta sólo en test: con una semilla fija el jitter deja de ser
  /// aleatorio y la banda se puede afirmar.
  static DecisionReintento decidir({
    required bool esRechazoDefinitivo,
    required int intentosPrevios,
    Random? azar,
  }) {
    final generador = azar ?? _azar;
    if (!esRechazoDefinitivo) {
      return DecisionReintento(
        gastaIntento: false,
        espera: _conJitter(esperaSinRed, generador),
      );
    }
    return DecisionReintento(
      gastaIntento: true,
      espera: _conJitter(_backoff(intentosPrevios + 1), generador),
    );
  }

  static final Random _azar = Random();

  /// "Equal jitter": la espera real cae en [mitad, entera] de la ventana.
  ///
  /// Sin esto, N dispositivos que se quedaron sin red al mismo tiempo vuelven
  /// TODOS en el mismo segundo cuando la red aparece —y le pegan al servidor
  /// juntos, que es como un corte breve se convierte en uno largo. Repartirlos
  /// en la ventana los desincroniza (HU-062).
  ///
  /// Se toma media ventana y no la entera para que el backoff siga siendo
  /// backoff: el piso crece con el escalón, y el resultado nunca supera la
  /// ventana, así que el tope no hay que volver a aplicarlo.
  ///
  /// > Ojo: en el salto al tope las bandas SÍ se solapan —el escalón 5 llega a
  /// > 160 s y el 6 arranca en 150 s—. La espera puede acortarse una vez, ahí.
  /// > Es el precio de repartir, y no rompe nada: el piso sigue subiendo.
  static Duration _conJitter(Duration ventana, Random azar) {
    final mitad = ventana.inMilliseconds ~/ 2;
    return Duration(milliseconds: mitad + azar.nextInt(mitad + 1));
  }

  /// Backoff exponencial con tope: 10s, 20s, 40s, 80s, 160s, 5min, 5min…
  ///
  /// El docstring del servicio prometía "reintentos con backoff" desde el día
  /// uno y no había ninguno: el ítem se reintentaba en el drenaje siguiente,
  /// que dispara con cada mutación local.
  static Duration _backoff(int intentos) {
    // El tope se chequea ANTES de desplazar: con un `maxIntentos` alto, `1 << n`
    // desborda en silencio y devolvería una espera absurda (o negativa).
    if (intentos >= 6) return esperaMaxima;
    final espera = esperaBase * (1 << (intentos - 1).clamp(0, 30));
    return espera > esperaMaxima ? esperaMaxima : espera;
  }
}
