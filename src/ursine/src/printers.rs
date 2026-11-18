//! Printers screen: CUPS printers and queued jobs.

use crate::prelude::*;
use ursine_api::{PrintJob, Printer};

use crate::package_ui::{text_row, ConfirmVm};

#[derive(Default)]
pub struct PrintersState {
    pub printers: Vec<Printer>,
    pub jobs: Vec<PrintJob>,
    pub busy: bool,
    pub action_busy: bool,
    pub error: Option<String>,
    pub message: Option<String>,
    pub name: String,
    pub uri: String,
    pub description: String,
    pub location: String,
    pub manual_driver: String,
    pub manual_ppd: String,
    pub manual_options: String,
    pub options_name: String,
    pub options_text: String,
    pub pending_remove: Option<String>,
    pub pending_cancel: bool,
}

impl PrintersState {
    pub fn apply(&mut self, printers: Vec<Printer>, jobs: Vec<PrintJob>) {
        self.printers = printers;
        self.jobs = jobs;
        self.error = None;
    }

    pub fn view(&self) -> Element<'_, Message> {
        let mut items = vec![ui::header(
            "Printers",
            (!self.busy && !self.action_busy).then_some(Message::RefreshPrinters),
        )];
        items.extend(ui::status(
            self.error.as_ref(),
            self.message.as_deref(),
            self.busy.then_some("Reading CUPS state…"),
            self.action_busy.then_some("Running printer action…"),
        ));

        let mut printers = settings::section().title(format!("Printers ({})", self.printers.len()));
        if self.printers.is_empty() {
            printers = printers.add(settings::item("Result", text("No printers configured.")));
        }
        for printer in &self.printers {
            let name = printer.name.clone();
            printers = printers.add(settings::item(
                format!(
                    "{} — {}{}",
                    printer.name,
                    printer.state,
                    if printer.is_default {
                        " · default"
                    } else {
                        ""
                    }
                ),
                column(vec![
                    row(vec![
                        button::text("Set default")
                            .on_press(Message::PrinterSetDefault(name.clone()))
                            .into(),
                        button::text(if printer.accepting { "Pause" } else { "Resume" })
                            .on_press(Message::PrinterPause(name.clone(), printer.accepting))
                            .into(),
                        button::destructive("Remove…")
                            .on_press(Message::PrinterRemoveRequested(name.clone()))
                            .into(),
                    ])
                    .spacing(8)
                    .into(),
                    text(format!(
                        "{}{}{}",
                        printer.description.as_deref().unwrap_or("no description"),
                        printer
                            .location
                            .as_ref()
                            .map(|location| format!(" · {location}"))
                            .unwrap_or_default(),
                        printer
                            .model
                            .as_ref()
                            .map(|model| format!(" · {model}"))
                            .unwrap_or_default()
                    ))
                    .into(),
                ])
                .spacing(4),
            ));
        }
        items.push(printers.into());

        items.push(
            settings::section()
                .title("Printer options")
                .add(settings::item(
                    "Printer",
                    text_input("Office", self.options_name.clone())
                        .on_input(Message::PrinterOptionsNameChanged),
                ))
                .add(settings::item(
                    "Options, one per line key=value",
                    text_input("media=A4", self.options_text.clone())
                        .on_input(Message::PrinterOptionsChanged),
                ))
                .add(settings::item(
                    "Paper, duplex, color: media=A4, Duplex=DuplexNoTumble, ColorModel=Gray",
                    button::text("Apply options").on_press_maybe(
                        (!self.action_busy).then_some(Message::PrinterOptionsRequested),
                    ),
                ))
                .into(),
        );

        items.push(
            settings::section()
                .title("Manual configuration")
                .add(settings::item(
                    "Driver or model",
                    text_input("everywhere or drv:///...", self.manual_driver.clone())
                        .on_input(Message::PrinterManualDriverChanged),
                ))
                .add(settings::item(
                    "PPD path (overrides driver)",
                    text_input("/usr/share/ppd/...", self.manual_ppd.clone())
                        .on_input(Message::PrinterManualPpdChanged),
                ))
                .add(settings::item(
                    "Options, one per line key=value",
                    text_input("Option=Value", self.manual_options.clone())
                        .on_input(Message::PrinterManualOptionsChanged),
                ))
                .add(settings::item(
                    "Use the name/URI/description/location above",
                    button::suggested("Add manual printer").on_press_maybe(
                        (!self.action_busy).then_some(Message::PrinterAddManualRequested),
                    ),
                ))
                .into(),
        );

        items.push(
            settings::section()
                .title("Add driverless printer")
                .add(settings::item(
                    "Name",
                    text_input("Office", self.name.clone()).on_input(Message::PrinterNameChanged),
                ))
                .add(settings::item(
                    "URI",
                    text_input("ipps://printer.local/ipp/print", self.uri.clone())
                        .on_input(Message::PrinterUriChanged),
                ))
                .add(settings::item(
                    "Description",
                    text_input("Office printer", self.description.clone())
                        .on_input(Message::PrinterDescriptionChanged),
                ))
                .add(settings::item(
                    "Location",
                    text_input("Desk", self.location.clone())
                        .on_input(Message::PrinterLocationChanged),
                ))
                .add(settings::item(
                    "Add",
                    button::text("Add printer").on_press_maybe(
                        (!self.action_busy).then_some(Message::PrinterAddRequested),
                    ),
                ))
                .into(),
        );

        let mut jobs = settings::section().title(format!("Queued jobs ({})", self.jobs.len()));
        if self.jobs.is_empty() {
            jobs = jobs.add(settings::item("Result", text("No queued jobs.")));
        }
        for job in &self.jobs {
            jobs = jobs.add(settings::item(
                format!("{} · {} · {}", job.id, job.printer, job.user),
                text(job.domain()),
            ));
        }
        jobs = jobs.add(settings::item(
            "Cancel all jobs",
            button::destructive("Cancel all…")
                .on_press_maybe((!self.action_busy).then_some(Message::PrinterCancelAllRequested)),
        ));
        items.push(jobs.into());

        scrollable(column(items).spacing(16).padding(24)).into()
    }
}

trait JobDetail {
    fn domain(&self) -> String;
}

impl JobDetail for PrintJob {
    fn domain(&self) -> String {
        format!(
            "{}{}{}",
            self.state.as_deref().unwrap_or("unknown state"),
            self.submitted
                .as_ref()
                .map(|submitted| format!(" · {submitted}"))
                .unwrap_or_default(),
            self.size
                .as_ref()
                .map(|size| format!(" · {size}"))
                .unwrap_or_default()
        )
    }
}

impl PrintersState {
    /// Pending remove/cancel-all confirmations as modal data.
    pub(crate) fn pending_confirm(&self) -> Option<ConfirmVm<'_>> {
        if let Some(name) = &self.pending_remove {
            return Some(ConfirmVm {
                title: "Confirm printer removal".to_string(),
                rows: vec![(
                    "Consequences".to_string(),
                    text_row(format!(
                        "Remove printer {name}? Queued jobs are not cancelled."
                    )),
                )],
                confirm: Message::PrinterRemoveConfirmed,
                cancel: Message::PrinterRemoveCancelled,
                armed: !self.action_busy,
                destructive: true,
            });
        }
        self.pending_cancel.then(|| ConfirmVm {
            title: "Confirm cancel all jobs".to_string(),
            rows: vec![(
                "Consequences".to_string(),
                text_row("Cancel every queued print job on this system?"),
            )],
            confirm: Message::PrinterCancelConfirmed,
            cancel: Message::PrinterCancelCancelled,
            armed: !self.action_busy,
            destructive: true,
        })
    }
}
