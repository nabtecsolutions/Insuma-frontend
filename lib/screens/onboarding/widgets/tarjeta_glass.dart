import 'package:flutter/material.dart';

/// Tarjeta Glassmorphic común.
class TarjetaGlass extends StatelessWidget {
  final Widget child;

  const TarjetaGlass({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0x26FFFFFF), // 15% opacidad
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0x40FFFFFF)), // 25% opacidad
      ),
      child: child,
    );
  }
}
