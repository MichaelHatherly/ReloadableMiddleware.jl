/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["*.jl"],
  theme: {
    extend: {},
  },
  plugins: [
    require('@tailwindcss/typography'),
  ],
}

