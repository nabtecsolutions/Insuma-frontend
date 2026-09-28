import 'package:flutter/material.dart';

class InsumaColors {
  static const primaryBlue = Color(0xFF2E86C1);
  static const backgroundLight = Color(0xFFF9FBFC);
  static const cardBorderLight = Color(
    0xFFEEEEEE,
  ); // equivalente a Colors.grey[100]
  static const alertRed = Color(0xFFFADBD8);
  static const alertYellow = Color(0xFFFCF3CF);
  static const financialPanelBg = Color(0xFFF5F9FD);
  static const financialPanelBorder = Color(0xFFE2EFF9);
  static const avatarBg = Color(0xFFEBF5FB);
  static const avatarBgNeutral = Color(0xFFF0F3F4);

  // ── #268 · semáforo de entrega ────────────────────────────────────────────
  //
  // Pares fondo/texto, y no colores sueltos: los dos existentes (`alertRed` y
  // `alertYellow`) están pensados SÓLO como fondo, así que cada pantalla que
  // los usa elige su propio color de texto a ojo y no hay dos iguales.
  //
  // Por qué estos tonos y no los que ya están:
  //  • `alertYellow` está reservado POR ESCRITO al aviso de serie frenada
  //    (HU-013), que aparece en la MISMA tarjeta. Reusarlo haría que dos avisos
  //    distintos se lean como el mismo.
  //  • El verde no se usa acá aunque un semáforo lo pida: en esta app el verde
  //    ya significa "recibido". Una entrega que todavía no llegó pintada de
  //    verde se leería como una que sí. El "viene en camino" va en azul, que es
  //    el color neutro de la casa.
  //  • El rojo del vencido NO choca con el rojo de "cancelado": un pedido
  //    cancelado no entra a Recepciones, que es la única pantalla con semáforo.
  static const entregaVencidaBg = Color(0xFFFDECEA);
  static const entregaVencidaFg = Color(0xFFB3261E);
  static const entregaHoyBg = Color(0xFFFFF1E0);
  static const entregaHoyFg = Color(0xFFB35309);
  static const entregaProximaBg = Color(0xFFEAF3FA);
  static const entregaProximaFg = Color(0xFF1B6698);
  static const entregaSinFechaBg = Color(0xFFEFF2F3);
  static const entregaSinFechaFg = Color(0xFF52666F);

  /// Chip del estado `en_espera` ("A recibir").
  ///
  /// Hasta #268 caía en el `default: Colors.orange` de `TarjetaPedido.badgeDe`,
  /// el mismo que `enviado` ("Sin confirmar").
  ///
  /// Los dos estados conviven en la **ficha del proveedor**, que lista TODOS
  /// los estados a propósito —su doc dice que "un borrador o algo 'A recibir'
  /// es justamente lo que se viene a buscar"—, y ahí los dos chips que más
  /// falta hacía distinguir eran del mismo color. NO conviven en Pedidos:
  /// `EstadosPedido.pestanaDe` devuelve `null` para `en_espera`, así que esa
  /// pantalla no lo lista nunca.
  static const estadoARecibir = Color(0xFF3F51B5);
}
