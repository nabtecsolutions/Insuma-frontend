import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Identificadores DERIVADOS de su contenido, iguales en el cliente y en el
/// servidor sin necesidad de coordinarse (HU-138).
///
/// El problema que resuelve: la tabla puente `insumo_proveedores` se rellena en
/// DOS lugares que no se hablan entre sí — la migración de Supabase (una vez, en
/// el servidor) y la migración local de Drift (una vez por dispositivo). Con ids
/// al azar, cada lado inventaría un id distinto PARA EL MISMO PAR insumo↔proveedor:
/// el pull hace `insertOnConflictUpdate`, que resuelve por clave primaria, así que
/// insertaría una SEGUNDA fila del mismo par y reventaría contra el índice único
/// `(insumo_id, proveedor_id)`.
///
/// Derivando el id del par, los dos lados llegan al MISMO id y la fila converge
/// sola. Se usa MD5 y no UUID v5 porque la paridad entre motores es trivialmente
/// verificable: en Postgres `md5(texto)` devuelve 32 hexadecimales en minúscula y
/// el cast `::uuid` los imprime con guiones; acá se hace exactamente lo mismo.
///
/// Módulo PURO: sin Flutter, sin IO, sin base de datos.
class IdDeterminista {
  const IdDeterminista._();

  /// Id del vínculo entre [insumoId] y [proveedorId].
  ///
  /// Equivalente exacto en Postgres:
  /// `md5(insumo_id::text || ':' || proveedor_id::text)::uuid`
  ///
  /// Los ids de la app se generan con `Uuid().v4()`, que ya produce minúsculas con
  /// guiones — la misma forma en que Postgres imprime un `uuid`. Por eso el texto
  /// de entrada es idéntico de los dos lados sin normalizar nada.
  static String parInsumoProveedor(String insumoId, String proveedorId) =>
      _comoUuid(md5.convert(utf8.encode('$insumoId:$proveedorId')).toString());

  /// Id del vínculo entre [proveedorId] y [categoriaId] (#262).
  ///
  /// Equivalente exacto en Postgres:
  /// `md5(proveedor_id::text || ':' || categoria_id::text)::uuid`
  ///
  /// Mismo motivo que [parInsumoProveedor]: la tabla `proveedor_categorias` se
  /// rellena por backfill en el servidor Y en cada dispositivo; sin id derivado
  /// del par, el `insertOnConflictUpdate` del pull duplicaría la fila.
  static String parProveedorCategoria(String proveedorId, String categoriaId) =>
      _comoUuid(
        md5.convert(utf8.encode('$proveedorId:$categoriaId')).toString(),
      );

  /// Id de la CATEGORÍA derivada de su (negocio, nombre normalizado) (#262).
  ///
  /// Equivalente exacto en Postgres:
  /// `md5(negocio_id::text || ':' || nombre_normalizado)::uuid`
  ///
  /// [nombreNormalizado] debe venir YA normalizado con la MISMA regla byte a byte
  /// en Dart y en SQL (la de HU-138: colapsar espacios/invisibles + btrim, SIN
  /// quitar acentos), o el backfill dual server+dispositivos no converge.
  static String categoria(String negocioId, String nombreNormalizado) =>
      _comoUuid(
        md5.convert(utf8.encode('$negocioId:$nombreNormalizado')).toString(),
      );

  /// Da forma 8-4-4-4-12 a 32 hexadecimales, como los imprime Postgres.
  static String _comoUuid(String hex32) {
    assert(
      hex32.length == 32,
      'se esperaban 32 hexadecimales, llegaron ${hex32.length}',
    );
    return '${hex32.substring(0, 8)}-${hex32.substring(8, 12)}-${hex32.substring(12, 16)}'
        '-${hex32.substring(16, 20)}-${hex32.substring(20)}';
  }
}
