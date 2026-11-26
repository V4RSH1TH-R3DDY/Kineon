use std::error::Error;
use std::io;

use neurosense::{MotionWindow, score_window};

fn main() -> Result<(), Box<dyn Error>> {
    let input: MotionWindow = serde_json::from_reader(io::stdin().lock())?;
    serde_json::to_writer_pretty(io::stdout().lock(), &score_window(&input))?;
    println!();
    Ok(())
}
