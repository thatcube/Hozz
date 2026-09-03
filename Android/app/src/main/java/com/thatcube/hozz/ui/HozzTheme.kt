package com.thatcube.hozz.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import com.thatcube.hozz.generated.GeneratedHozzColors

private val LightColors = lightColorScheme(
    primary = GeneratedHozzColors.actionFill.light,
    onPrimary = GeneratedHozzColors.onAction.light,
    primaryContainer = GeneratedHozzColors.blueWash.light,
    onPrimaryContainer = GeneratedHozzColors.ink.light,
    secondary = GeneratedHozzColors.actionText.light,
    background = GeneratedHozzColors.air.light,
    onBackground = GeneratedHozzColors.ink.light,
    surface = GeneratedHozzColors.cardTop.light,
    onSurface = GeneratedHozzColors.ink.light,
    surfaceVariant = GeneratedHozzColors.mist.light,
    onSurfaceVariant = GeneratedHozzColors.inkSoft.light,
    outline = GeneratedHozzColors.line.light,
    error = GeneratedHozzColors.warning.light,
)

private val DarkColors = darkColorScheme(
    primary = GeneratedHozzColors.actionFill.dark,
    onPrimary = GeneratedHozzColors.onAction.dark,
    primaryContainer = GeneratedHozzColors.blueWash.dark,
    onPrimaryContainer = GeneratedHozzColors.ink.dark,
    secondary = GeneratedHozzColors.actionText.dark,
    background = GeneratedHozzColors.air.dark,
    onBackground = GeneratedHozzColors.ink.dark,
    surface = GeneratedHozzColors.cardTop.dark,
    onSurface = GeneratedHozzColors.ink.dark,
    surfaceVariant = GeneratedHozzColors.mist.dark,
    onSurfaceVariant = GeneratedHozzColors.inkSoft.dark,
    outline = GeneratedHozzColors.line.dark,
    error = GeneratedHozzColors.warning.dark,
)

@Composable
fun HozzTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
