import 'package:intl/intl.dart';

import '../../core/i18n/strings.dart';
import '../../core/time/venue_time.dart';
import '../../data/shift_market_repository.dart';

/// Employee-facing words for the schedule screen, in English and Spanish.
extension ShiftStrings on T {
  String get schedule => es ? 'Horario' : 'Schedule';
  String get myShifts => es ? 'Mis turnos' : 'My shifts';
  String get openShifts => es ? 'Turnos abiertos' : 'Open shifts';
  String get requests => es ? 'Solicitudes' : 'Requests';
  String get availability => es ? 'Disponibilidad' : 'Availability';

  // Short tab labels (four must fit across a phone).
  String get tabOpen => es ? 'Abiertos' : 'Open shifts';
  String get tabAvailability => es ? 'Disponible' : 'Availability';

  // My shifts
  String get noUpcoming => es ? 'No tiene turnos próximos.' : 'No upcoming shifts.';
  String get drop => es ? 'Dejar turno' : 'Drop';
  String get giveToCoworker => es ? 'Dar a un compañero' : 'Give to a coworker';
  String get inProgress => es ? 'En curso' : 'In progress';
  String dropClosed(num hours) => es
      ? 'Ya no se puede dejar: cierra $hours horas antes de la llegada. Hable con su gerente.'
      : 'Drops close $hours hours before call time. Talk to your manager.';
  String get dropTitle => es ? '¿Dejar este turno?' : 'Drop this shift?';
  String get dropHelp => es
      ? 'Su gerente ve el motivo y decide. Sigue siendo su turno hasta que lo apruebe.'
      : 'Your manager sees your reason and decides. It stays your shift until they approve.';
  String get whyHint => es ? '¿Por qué?' : 'Why?';
  List<String> get dropReasons => es
      ? const ['Estoy enfermo', 'Escuela', 'Familia', 'Otro trabajo']
      : const ['Sick', 'School', 'Family', 'Other job'];
  String get sendRequest => es ? 'Enviar solicitud' : 'Send request';
  String get dropRequested => es ? 'Pidió dejarlo · esperando al gerente' : 'Drop requested · waiting for a manager';
  String offeredTo(String name) => es ? 'Ofrecido a $name · esperando respuesta' : 'Offered to $name · waiting for them';
  String swapWaiting(String name) => es ? 'Cambio con $name · esperando al gerente' : 'Swap with $name · waiting for a manager';

  // Give to a coworker
  String get giveTitle => es ? 'Dar este turno a…' : 'Give this shift to…';
  String get giveHelp => es ? 'Su compañero acepta y luego un gerente aprueba.' : 'Your coworker accepts, then a manager approves.';
  String get searchName => es ? 'Buscar nombre' : 'Search name';
  String get noCoworkers => es ? 'Ningún compañero puede tomar este turno.' : 'No coworker can take this shift.';
  String get saidAvailable => es ? 'Dijo que puede' : 'Said available';
  String get saidUnavailable => es ? 'Dijo que no puede' : 'Said unavailable';
  String offerTitle(String name) => es ? '¿Ofrecer a $name?' : 'Offer to $name?';
  String get noteOptional => es ? 'Nota (opcional)' : 'Note (optional)';
  String get offer => es ? 'Ofrecer' : 'Offer';
  String offerSent(String name) => es ? 'Oferta enviada a $name' : 'Offer sent to $name';

  // Open shifts
  String get pickUp => es ? 'Tomar turno' : 'Pick up';
  String get requested => es ? 'Solicitado' : 'Requested';
  String get cancelRequest => es ? 'Cancelar solicitud' : 'Cancel request';
  String get managerApproves => es ? 'Un gerente aprueba cada turno que pida.' : 'A manager approves each pickup.';
  String get pickupsInstant => es ? 'Los turnos que tome se confirman al instante.' : 'Pickups are confirmed right away.';
  String get pickupsOff => es ? 'No se pueden tomar turnos en este lugar.' : 'Picking up shifts is turned off at this venue.';
  String get noOpenShifts => es ? 'No hay turnos abiertos para sus puestos ahora.' : 'No open shifts for your roles right now.';
  String get cannotTake => es ? 'No puede tomar este turno' : 'You can\'t take this one';
  String get requestSent => es ? 'Solicitud enviada. Un gerente la revisará.' : 'Request sent. A manager will review it.';
  String get itsYours => es ? '¡Es suyo! Aparece en Mis turnos.' : 'It\'s yours! It\'s in My shifts.';
  String get pickUpTitle => es ? '¿Pedir este turno?' : 'Ask for this shift?';
  String get youSaidCant => es ? 'Usted dijo que no puede' : 'You said you can\'t';

  // Requests
  String get offersToYou => es ? 'Ofrecidos a usted' : 'Offered to you';
  String get waiting => es ? 'En espera' : 'Waiting';
  String get history => es ? 'Historial' : 'History';
  String get accept => es ? 'Aceptar' : 'Accept';
  String get decline => es ? 'Rechazar' : 'Decline';
  String offerFrom(String name) => es ? '$name quiere darle este turno' : '$name wants to give you this shift';
  String get acceptHelp => es ? 'Si acepta, un gerente lo aprueba.' : 'If you accept, a manager approves it.';
  String get accepted => es ? 'Aceptado. Un gerente lo aprobará.' : 'Accepted. A manager will approve it.';
  String get declined => es ? 'Rechazado' : 'Declined';
  String get cancelled => es ? 'Cancelado' : 'Cancelled';
  String get noRequests => es ? 'Todavía no tiene solicitudes.' : 'No requests yet.';
  String kindLabel(ShiftRequestKind k) => switch (k) {
        ShiftRequestKind.pickup => es ? 'Tomar turno' : 'Pickup',
        ShiftRequestKind.drop => es ? 'Dejar turno' : 'Drop',
        ShiftRequestKind.swap => es ? 'Cambio' : 'Swap',
      };
  String statusLabel(ShiftRequestStatus s) => switch (s) {
        ShiftRequestStatus.pending => es ? 'Esperando al gerente' : 'Waiting for manager',
        ShiftRequestStatus.offered => es ? 'Esperando al compañero' : 'Waiting for coworker',
        ShiftRequestStatus.approved => es ? 'Aprobado' : 'Approved',
        ShiftRequestStatus.denied => es ? 'Negado' : 'Denied',
        ShiftRequestStatus.cancelled => es ? 'Cancelado' : 'Cancelled',
        ShiftRequestStatus.expired => es ? 'Vencido' : 'Expired',
      };
  String swapTo(String name) => es ? 'Para $name' : 'To $name';
  String swapFrom(String name) => es ? 'De $name' : 'From $name';
  String decidedBy(String name) => es ? 'por $name' : 'by $name';

  // Availability
  String get availabilityHelp => es ? 'Diga a su gerente qué eventos puede trabajar.' : 'Tell your manager which events you can work.';
  String get iCanWork => es ? 'Puedo' : 'I can work';
  String get iCant => es ? 'No puedo' : 'I can\'t';
  String get scheduledTag => es ? 'Programado' : 'Scheduled';
  String get daysOff => es ? 'Días que no puedo trabajar' : 'Days I can\'t work';
  String get daysOffHelp => es ? 'Vacaciones, viajes, exámenes.' : 'Vacation, trips, exams.';
  String get addDates => es ? 'Agregar fechas' : 'Add dates';
  String get remove => es ? 'Quitar' : 'Remove';
  String get inDaysOff => es ? 'En sus días libres' : 'In your days off';
  String get upcomingEvents => es ? 'Próximos eventos' : 'Upcoming events';
  String get noEvents => es ? 'No hay eventos próximos.' : 'No upcoming events.';
  String get noDaysOff => es ? 'Ninguno.' : 'None.';
  String get saved => es ? 'Guardado' : 'Saved';
  String get save => es ? 'Guardar' : 'Save';

  String get locale => es ? 'es' : 'en';

  /// "Fri, Nov 6" / "vie, 6 nov" at the venue.
  String day(DateTime utc, String zone) => _fmt('EEE, MMM d', utc, zone);

  /// "5:30 PM" at the venue.
  String clock(DateTime utc, String zone) => _fmt('h:mm a', utc, zone);

  /// A calendar date (UTC midnight), "Nov 6".
  String date(DateTime d) {
    try {
      return DateFormat.MMMd(locale).format(d);
    } catch (_) {
      return DateFormat.MMMd().format(d);
    }
  }

  String _fmt(String pattern, DateTime utc, String zone) {
    final local = atVenue(utc, zone);
    try {
      return DateFormat(pattern, locale).format(local);
    } catch (_) {
      return DateFormat(pattern).format(local);
    }
  }
}
