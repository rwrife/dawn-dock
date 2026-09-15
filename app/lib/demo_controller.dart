class DemoController {
  static const initialSchedule = 'Weekdays at 7:00 AM';
  static const proposedSchedule = 'Weekdays at 7:30 AM';

  int revision = 1;
  String schedule = initialSchedule;
  bool hasReceipt = false;

  void applySampleChange() {
    if (hasReceipt) return;
    schedule = proposedSchedule;
    revision += 1;
    hasReceipt = true;
  }

  void reset() {
    revision = 1;
    schedule = initialSchedule;
    hasReceipt = false;
  }
}
