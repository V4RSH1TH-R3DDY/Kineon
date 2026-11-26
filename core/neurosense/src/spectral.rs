use std::f64::consts::TAU;

use rustfft::{FftPlanner, num_complex::Complex};

pub(crate) fn detrend(samples: &[[f64; 3]]) -> Vec<[f64; 3]> {
    let count = samples.len() as f64;
    let center = (count - 1.0) / 2.0;
    let x2 = count * (count * count - 1.0) / 12.0;
    let mut mean = [0.0; 3];
    let mut slope = [0.0; 3];
    for (index, sample) in samples.iter().enumerate() {
        for axis in 0..3 {
            mean[axis] += sample[axis];
            slope[axis] += (index as f64 - center) * sample[axis];
        }
    }
    samples
        .iter()
        .enumerate()
        .map(|(index, sample)| {
            std::array::from_fn(|axis| {
                sample[axis] - mean[axis] / count - (index as f64 - center) * slope[axis] / x2
            })
        })
        .collect()
}

pub(crate) struct Spectrum {
    power: Vec<f64>,
    bin_hz: f64,
}

impl Spectrum {
    pub(crate) fn welch(samples: &[[f64; 3]], fs: f64, planner: &mut FftPlanner<f64>) -> Self {
        let len = samples.len().min((fs * 2.0) as usize);
        let hop = len - len / 2;
        let window: Vec<_> = (0..len)
            .map(|i| 0.5 - 0.5 * (TAU * i as f64 / len as f64).cos())
            .collect();
        let scale = 1.0 / (fs * window.iter().map(|w| w * w).sum::<f64>());
        let fft = planner.plan_fft_forward(len);
        let mut scratch = vec![Complex::default(); fft.get_inplace_scratch_len()];
        let mut buffer = vec![Complex::default(); len];
        let mut power = vec![0.0; len / 2 + 1];
        let mut segments = 0;

        for start in (0..=samples.len() - len).step_by(hop) {
            let segment = &samples[start..start + len];
            segments += 1;
            for axis in 0..3 {
                let mean = segment.iter().map(|s| s[axis]).sum::<f64>() / len as f64;
                for (index, bin) in buffer.iter_mut().enumerate() {
                    *bin = Complex::new((segment[index][axis] - mean) * window[index], 0.0);
                }
                fft.process_with_scratch(&mut buffer, &mut scratch);
                for (index, value) in power.iter_mut().enumerate() {
                    let one_sided = if index == 0 || index * 2 == len {
                        1.0
                    } else {
                        2.0
                    };
                    *value += buffer[index].norm_sqr() * one_sided * scale;
                }
            }
        }
        for value in &mut power {
            *value /= segments as f64;
        }
        Self {
            power,
            bin_hz: fs / len as f64,
        }
    }

    pub(crate) fn finite(&self) -> bool {
        self.power.iter().all(|p| p.is_finite())
    }

    pub(crate) fn band_power(&self, low: f64, high: f64) -> f64 {
        self.power_where(|hz| hz >= low && hz < high)
    }

    pub(crate) fn power_where(&self, include: impl Fn(f64) -> bool) -> f64 {
        let mut previous = None;
        let mut area = 0.0;
        for (index, power) in self.power.iter().copied().enumerate() {
            if include(index as f64 * self.bin_hz) {
                if let Some(last) = previous {
                    area += (last + power) * self.bin_hz * 0.5;
                }
                previous = Some(power);
            }
        }
        area
    }

    pub(crate) fn dominant(&self, low: f64, high: f64) -> (f64, f64) {
        let mut best = None;
        for (index, &power) in self.power.iter().enumerate() {
            let hz = index as f64 * self.bin_hz;
            if (low..high).contains(&hz) && best.is_none_or(|(_, peak)| power > peak) {
                best = Some((hz, power));
            }
        }
        best.unwrap_or((0.0, 0.0))
    }

    pub(crate) fn local_peak(&self, low: f64, high: f64) -> f64 {
        // Match the middle bin of flat-topped peaks as well as ordinary local maxima.
        let mut best = 0.0_f64;
        let mut index = 1;
        while index + 1 < self.power.len() {
            if self.power[index - 1] < self.power[index] {
                let start = index;
                while index + 1 < self.power.len() && self.power[index + 1] == self.power[start] {
                    index += 1;
                }
                let hz = ((start + index) / 2) as f64 * self.bin_hz;
                if index + 1 < self.power.len()
                    && self.power[index] > self.power[index + 1]
                    && (low..high).contains(&hz)
                {
                    best = best.max(self.power[index]);
                }
            }
            index += 1;
        }
        best
    }
}
