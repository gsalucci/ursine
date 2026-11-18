//! Shared screen chrome: the title row and the status lines every screen shows
//! in the same order (error, message, busy, action-busy).

use crate::prelude::*;

/// Title row with a trailing Refresh button.
pub fn header(title: &str, refresh: Option<Message>) -> Element<'_, Message> {
    header_with(
        title,
        vec![button::text("Refresh").on_press_maybe(refresh).into()],
    )
}

/// Title row with caller-provided trailing widgets (Refresh, Scan, …).
pub fn header_with<'a>(title: &'a str, tail: Vec<Element<'a, Message>>) -> Element<'a, Message> {
    let mut items: Vec<Element<'a, Message>> = vec![
        text::title2(title).into(),
        text("").width(Length::Fill).into(),
    ];
    items.extend(tail);
    row(items).spacing(12).width(Length::Fill).into()
}

/// Error, message and busy lines, in the one order every screen uses.
pub fn status<'a>(
    error: Option<&'a String>,
    message: Option<&'a str>,
    busy: Option<&'a str>,
    action_busy: Option<&'a str>,
) -> Vec<Element<'a, Message>> {
    let mut items: Vec<Element<'a, Message>> = Vec::new();
    if let Some(error) = error {
        items.push(selectable_text(error.clone()).into());
    }
    if let Some(message) = message {
        items.push(text(message).into());
    }
    if let Some(busy) = busy {
        items.push(text(busy).into());
    }
    if let Some(action_busy) = action_busy {
        items.push(text(action_busy).into());
    }
    items
}
