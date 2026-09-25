// What shiny surfaces reflect: a panorama of distant lit windows and lamps at street level.
shader_type sky;
uniform sampler2D pano : source_color, filter_linear;
void sky() {
	COLOR = texture(pano, SKY_COORDS).rgb;
}
