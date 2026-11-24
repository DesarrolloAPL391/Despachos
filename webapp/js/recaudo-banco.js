// recaudo-banco.js — Lee el "Archivo Recaudo" del Banco de Bogotá tal como llega por correo (sql/142, 202).
//
// Cada zip trae UN día en dos formas, con los mismos pagos y en el mismo orden:
//   · pobl<aaaammdd>.lst   → reporte legible: FACTURA (la cédula con ceros), VALOR, VALOR ADICIONAL,
//                            CAJERO, TRANSAC., FECHA DE PAGO, y al final sus totales.
//   · pobl_BOG_<aaaammdd>  → formato Asobancaria de 220 caracteres: 01 encabezado, 05 lote, 06 un pago,
//                            08 y 09 los totales de control.
// y a veces el Excel "RecaudosDiasAnteriores", que se sigue leyendo como antes (solo si no viene lo otro).
//
// La referencia de cada pago es la cédula del conductor: eso es lo que deja saber QUIÉN pagó.
// Aquí no hay DOM ni red: son funciones puras, para poder probarlas fuera del navegador.

const plata = (s) => Number(String(s || '').replace(/[$\s,]/g, ''));
const iso8 = (s) => (/^\d{8}$/.test(s) ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : '');
const sinTilde = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '');
const centavos = (n) => Math.round(Number(n) * 100);

// Por qué un archivo no cuadra con sus propios totales ('' si cuadra)
function noCuadra(filas, control) {
  if (filas.length !== control.n) return `leí ${filas.length} pagos y el banco dice ${control.n}`;
  const suma = filas.reduce((s, f) => s + centavos(f.valor), 0);
  if (suma === centavos(control.total)) return '';
  return `los pagos suman $${(suma / 100).toLocaleString('es-CO')} y el banco dice $${Number(control.total).toLocaleString('es-CO')}`;
}

// La llave de un día: la misma para el .lst y para el Asobancaria de ese día, y la línea es el número
// del pago (1, 2, 3…) en el orden del banco, que es el mismo en los dos. Cargar uno y después el otro,
// o el mismo zip dos veces, no duplica nada (unique archivo + linea en recaudos_banco).
export const archivoDia = (fecha) => 'RECAUDO-BOG-' + String(fecha).replace(/-/g, '');

function fila(i, fechaPago, fechaRecaudo, banco, ref, valor, cajero, transac) {
  return {
    linea: i + 1, fecha: fechaPago || fechaRecaudo, fecha_aplica: fechaRecaudo,
    tipo: 'ARCHIVO RECAUDO', origen: cajero ? 'Cajero ' + cajero : '', banco,
    transaccion: 'CREDITO RECAUDOS SERVICIOS', ref1: ref, ref2: '', valor, comprobante: transac || '',
  };
}

// ---- El reporte .lst ----
const RE_LST = /^\s*(\d{6,})\s+\$?([\d,]+\.\d{2})\s+\$?([\d,]+\.\d{2})\s+(\S+)\s+(\S+)\s+(\d{4}-\d{2}-\d{2})\s*$/;

export function leerLst(texto) {
  const t = String(texto || '');
  const m = /FECHA RECAUDO:\s*(\d{4}-\d{2}-\d{2})/.exec(t);
  if (!m) throw new Error('no parece un reporte de recaudo del banco (no dice FECHA RECAUDO)');
  const fecha = m[1];
  const mb = /ENTIDAD DE ABONO:\s*(.+?)(?:\s{2,}|\r?\n|$)/.exec(t);
  const banco = sinTilde(mb ? mb[1].trim() : 'Banco de Bogota');
  const filas = [];
  let adicional = 0;
  for (const l of t.split(/\r?\n/)) {
    const x = RE_LST.exec(l);
    if (!x) continue;
    adicional += plata(x[3]);
    filas.push(fila(filas.length, x[6], fecha, banco, x[1], plata(x[2]), x[4], x[5]));
  }
  const mn = /Total Operaciones:\s*(\d+)/.exec(t), mv = /Valor Total Compensado:\s*\$?([\d,]+\.\d{2})/.exec(t);
  if (!mn || !mv) throw new Error('el reporte no trae sus totales (Total Operaciones / Valor Total Compensado)');
  const control = { n: Number(mn[1]), total: plata(mv[1]) };
  const falla = noCuadra(filas, control);
  if (falla) throw new Error(`el reporte del ${fecha} no cuadra con sus totales: ${falla}`);
  return { fecha, banco, filas, control, adicional, fuente: 'lst' };
}

// ---- El archivo Asobancaria (pobl_BOG_aaaammdd) ----
// 01: fecha de recaudo en [18,26). 06: referencia [2,66), fecha de pago [100,108), valor en centavos
// [114,128), número del pago [128,186). 08/09: cantidad [2,11) y valor en centavos [11,29).
export function leerAsobancaria(texto, banco = 'Banco de Bogota') {
  const L = String(texto || '').split(/\r?\n/).filter((l) => l.trim());
  const r01 = L.find((l) => l.startsWith('01'));
  const r09 = L.find((l) => l.startsWith('09'));
  const fecha = r01 ? iso8(r01.slice(18, 26)) : '';
  if (!fecha || !r09) throw new Error('no parece un archivo de recaudo Asobancaria (falta el encabezado o el control)');
  const filas = [];
  for (const l of L.filter((x) => x.startsWith('06'))) {
    const ref = l.slice(2, 66), cent = l.slice(114, 128);
    if (l.length < 128 || !/^\d+$/.test(ref) || !/^\d+$/.test(cent)) {
      throw new Error(`el pago ${filas.length + 1} del ${fecha} no tiene la forma esperada`);
    }
    filas.push(fila(filas.length, iso8(l.slice(100, 108)), fecha, banco, ref.replace(/^0+(?=\d{18})/, ''),
      Number(cent) / 100, '', l.slice(128, 186).trim().replace(/^0+(?=\d)/, '')));
  }
  const control = { n: Number(r09.slice(2, 11)), total: Number(r09.slice(11, 29)) / 100 };
  const falla = noCuadra(filas, control);
  if (falla) throw new Error(`el archivo del banco del ${fecha} no cuadra con sus totales: ${falla}`);
  return { fecha, banco, filas, control, adicional: 0, fuente: 'asobancaria' };
}

const esLst = (n) => /\.lst$/i.test(n);
const esAsob = (n) => /(^|[\\/])pobl_BOG_\d{8}$/i.test(n) || /_BOG_\d{8}(\.txt)?$/i.test(n);
const esXls = (n) => /\.xlsx?$/i.test(n);
export const tipoArchivoBanco = (n) => (esLst(n) ? 'lst' : esAsob(n) ? 'asobancaria' : esXls(n) ? 'xls' : /\.zip$/i.test(n) ? 'zip' : '');

// Lo que sale de un zip ya abierto: `entradas` = [{ nombre, texto }] de los .lst y Asobancaria, y
// `xls` = los nombres de los Excel que traía. Devuelve un lote por día. Si vienen el .lst y el
// Asobancaria del mismo día se usa el .lst (trae cajero, transacción y fecha de pago) y se exige que
// el otro diga EXACTAMENTE lo mismo: si no, ese día no se carga.
export function lotesDeZip(entradas, xls = []) {
  const porDia = new Map();
  const errores = [];
  for (const e of entradas) {
    try {
      const r = esLst(e.nombre) ? leerLst(e.texto) : leerAsobancaria(e.texto);
      const d = porDia.get(r.fecha) || {};
      d[r.fuente] = r;
      porDia.set(r.fecha, d);
    } catch (err) { errores.push(`${e.nombre}: ${err.message || err}`); }
  }
  const lotes = [];
  for (const [fecha, d] of [...porDia].sort()) {
    const a = d.lst || d.asobancaria, b = d.lst && d.asobancaria;
    if (b) {
      const igual = a.filas.length === b.filas.length && a.filas.every((f, i) =>
        f.ref1.replace(/^0+/, '') === b.filas[i].ref1.replace(/^0+/, '') && centavos(f.valor) === centavos(b.filas[i].valor));
      if (!igual) { errores.push(`${fecha}: el reporte .lst y el archivo del banco no dicen lo mismo; no se cargó`); continue; }
    }
    lotes.push({ archivo: archivoDia(fecha), fecha, filas: a.filas, control: a.control, fuente: b ? 'lst+asobancaria' : a.fuente });
  }
  return { lotes, errores, xls_ignorados: lotes.length ? xls : [] };
}
