import 'package:flutter/material.dart';

Future<T?> chooseSetting<T>(
  BuildContext context,
  String title,
  T selected,
  Map<T, String> choices,
) => showModalBottomSheet<T>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: RadioGroup<T>(
          groupValue: selected,
          onChanged: (value) => Navigator.pop(context, value ?? selected),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final entry in choices.entries)
                RadioListTile<T>(
                  value: entry.key,
                  title: Text(entry.value),
                  toggleable: true,
                ),
            ],
          ),
        ),
      ),
    ),
  ),
);
