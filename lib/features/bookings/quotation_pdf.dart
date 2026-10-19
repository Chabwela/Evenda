import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/format.dart';
import '../../domain/models.dart';

const _forest = PdfColor.fromInt(0xFF1B3B22);
const _bronze = PdfColor.fromInt(0xFF996633);
const _ink2 = PdfColor.fromInt(0xFF4A4F4B);
const _sand = PdfColor.fromInt(0xFFE8DFCC);
const _cream = PdfColor.fromInt(0xFFF7F3EA);

/// Plain-text summary for WhatsApp (sent only on an explicit user action).
String quotationSummaryText(QuoteRequest q, Quotation qt) {
  final b = StringBuffer()
    ..writeln('*Quotation v${qt.version}* — ${q.supplier.name} for ${q.requester.name}')
    ..writeln('Dates: ${EvDates.range(q.neededFrom, q.neededTo)}')
    ..writeln();
  for (final i in qt.items) {
    b.writeln('• ${i.quantity} × ${i.description} @ ${Money.k(i.unitPrice)}${i.days > 1 ? ' × ${i.days} days' : ''} = ${Money.k(i.lineTotal)}');
  }
  for (final c in qt.charges) {
    b.writeln('• ${c.label}: ${Money.k(c.amount)}');
  }
  b
    ..writeln()
    ..writeln('*Total: ${Money.zmw(qt.total)}*');
  if (qt.depositAmount > 0) b.writeln('Deposit: ${Money.zmw(qt.depositAmount)}${qt.depositTerms != null ? ' (${qt.depositTerms})' : ''}');
  if (qt.paymentTerms.isNotEmpty) b.writeln('Payment: ${qt.paymentTerms}');
  b.writeln('Valid until ${EvDates.day(qt.validUntil)}');
  b.writeln('\nSent via Evenda');
  return b.toString();
}

Future<Uint8List> buildQuotationPdf(QuoteRequest q, Quotation qt) async {
  final font = pw.Font.ttf(await rootBundle.load('assets/fonts/Figtree.ttf'));
  final display = pw.Font.ttf(await rootBundle.load('assets/fonts/Fraunces.ttf'));
  final doc = pw.Document(title: 'Quotation v${qt.version} — ${q.supplier.name}', author: q.supplier.name, creator: 'Evenda');
  final base = pw.TextStyle(font: font, fontSize: 10, color: PdfColors.black);

  pw.Widget cell(String t, {bool right = false, bool head = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: pw.Text(t, textAlign: right ? pw.TextAlign.right : pw.TextAlign.left, style: base.copyWith(color: head ? _ink2 : PdfColors.black, fontSize: head ? 8.5 : 10)),
      );

  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(q.supplier.name, style: base.copyWith(font: display, fontSize: 20, color: _forest)),
            if (q.supplier.neighbourhood != null) pw.Text('${q.supplier.neighbourhood}, Lusaka', style: base.copyWith(color: _ink2)),
            if (q.supplier.phone != null) pw.Text(ZambianPhone.display(q.supplier.phone), style: base.copyWith(color: _ink2)),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('QUOTATION', style: base.copyWith(fontSize: 9, color: _bronze, letterSpacing: 1.5)),
          pw.Text('Version ${qt.version}', style: base.copyWith(fontSize: 14)),
          pw.Text('Issued ${EvDates.dayShort(qt.createdAt)} ${qt.createdAt.year}', style: base.copyWith(color: _ink2)),
          pw.Text('Valid until ${EvDates.day(qt.validUntil)}', style: base.copyWith(color: _ink2)),
        ]),
      ]),
      pw.SizedBox(height: 24),
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: const pw.BoxDecoration(color: _cream),
        child: pw.Row(children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('PREPARED FOR', style: base.copyWith(fontSize: 8, color: _ink2, letterSpacing: 1)),
              pw.Text(q.requester.name, style: base.copyWith(fontSize: 12)),
            ]),
          ),
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('DATES', style: base.copyWith(fontSize: 8, color: _ink2, letterSpacing: 1)),
              pw.Text(EvDates.range(q.neededFrom, q.neededTo), style: base.copyWith(fontSize: 12)),
            ]),
          ),
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('ARRANGEMENT', style: base.copyWith(fontSize: 8, color: _ink2, letterSpacing: 1)),
              pw.Text(q.fulfilment.label, style: base.copyWith(fontSize: 12)),
            ]),
          ),
        ]),
      ),
      pw.SizedBox(height: 18),
      pw.Table(
        columnWidths: const {0: pw.FlexColumnWidth(5), 1: pw.FlexColumnWidth(1.2), 2: pw.FlexColumnWidth(1.6), 3: pw.FlexColumnWidth(1), 4: pw.FlexColumnWidth(1.8)},
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _sand, width: 0.6), bottom: pw.BorderSide(color: _sand, width: 0.6)),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _forest, width: 1))),
            children: [cell('ITEM', head: true), cell('QTY', right: true, head: true), cell('UNIT', right: true, head: true), cell('DAYS', right: true, head: true), cell('AMOUNT (ZMW)', right: true, head: true)],
          ),
          for (final i in qt.items)
            pw.TableRow(children: [
              cell(i.description),
              cell('${i.quantity}', right: true),
              cell(Money.zmw(i.unitPrice).substring(4), right: true),
              cell('${i.days}', right: true),
              cell(Money.zmw(i.lineTotal).substring(4), right: true),
            ]),
          for (final ch in qt.charges)
            pw.TableRow(children: [cell(ch.label), cell(''), cell(''), cell(''), cell(Money.zmw(ch.amount).substring(4), right: true)]),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('Subtotal ${Money.zmw(qt.subtotal)}', style: base.copyWith(color: _ink2)),
          pw.SizedBox(height: 4),
          pw.Text('Total ${Money.zmw(qt.total)}', style: base.copyWith(fontSize: 15, color: _forest)),
          if (qt.depositAmount > 0) pw.Text('Deposit ${Money.zmw(qt.depositAmount)}', style: base.copyWith(color: _ink2)),
        ]),
      ),
      pw.SizedBox(height: 24),
      if (qt.depositTerms != null) _section('Deposit terms', qt.depositTerms!, base),
      if (qt.paymentTerms.isNotEmpty) _section('Payment terms', qt.paymentTerms, base),
      if (qt.conditions.isNotEmpty) _section('Conditions', qt.conditions, base),
      pw.Spacer(),
      pw.Divider(color: _sand),
      pw.Text(
        'This quotation becomes a booking only when accepted on Evenda, at which point stock is reserved. Payments are arranged between the parties.',
        style: base.copyWith(fontSize: 8, color: _ink2),
      ),
    ]),
  ));
  return doc.save();
}

pw.Widget _section(String title, String body, pw.TextStyle base) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(title.toUpperCase(), style: base.copyWith(fontSize: 8, color: _ink2, letterSpacing: 1)),
        pw.SizedBox(height: 2),
        pw.Text(body, style: base),
      ]),
    );

Future<void> shareQuotationPdf(QuoteRequest q, Quotation qt) async {
  final bytes = await buildQuotationPdf(q, qt);
  final safe = q.supplier.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
  await Printing.sharePdf(bytes: bytes, filename: 'Quotation-$safe-v${qt.version}.pdf');
}
